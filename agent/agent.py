#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
探针客户端（Agent）
- 仅依赖 Python3 标准库，常驻内存约 10MB
- 通过 TCP 长连接向服务端推送紧凑的 JSON 数组，静态信息仅在变化时发送，最大限度节省流量
"""
import hashlib
import json
import os
import re
import signal
import socket
import sys
import threading
import time
import urllib.request
from collections import deque
from datetime import date

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
with open(os.path.abspath(__file__), "rb") as _f:
    SELF_SHA = hashlib.sha256(_f.read()).hexdigest()   # 自身版本，用于与主控比对
CONFIG_FILE = os.path.join(BASE_DIR, "config.json")
STATE_FILE = os.path.join(BASE_DIR, "state.json")

# 不计入流量统计的虚拟网卡前缀
NET_EXCLUDE = ("lo", "docker", "veth", "br-", "virbr", "vnet", "tap", "tun", "kube",
               "cni", "flannel", "cali", "dummy", "ifb", "lxc", "cilium", "zt", "tailscale")
# 计入硬盘统计的文件系统
DISK_FS = {"ext2", "ext3", "ext4", "xfs", "btrfs", "zfs", "reiserfs", "jfs", "f2fs",
           "vfat", "exfat", "ntfs", "fuseblk", "simfs", "bcachefs"}
DISK_DEV_RE = re.compile(r"^(sd[a-z]+|vd[a-z]+|xvd[a-z]+|hd[a-z]+|nvme\d+n\d+|mmcblk\d+)$")

UA = "Mozilla/5.0 probe-agent"


def log(*args):
    print(time.strftime("[%Y-%m-%d %H:%M:%S]"), *args, flush=True)


def read_file(path, default=""):
    try:
        with open(path, "r", errors="ignore") as f:
            return f.read()
    except Exception:
        return default


def http_get(url, timeout=6):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read(4096).decode("utf-8", "ignore")


# ---------------------------------------------------------------- 静态信息

def detect_virt():
    """识别虚拟化类型"""
    try:
        out = os.popen("systemd-detect-virt 2>/dev/null").read().strip()
        if out and out != "none":
            return out.lower()
    except Exception:
        pass
    if os.path.exists("/.dockerenv"):
        return "docker"
    environ = read_file("/proc/1/environ")
    if "container=lxc" in environ:
        return "lxc"
    if "container=" in environ:
        return "container"
    if os.path.exists("/proc/vz") and not os.path.exists("/proc/bc"):
        return "openvz"
    cgroup = read_file("/proc/1/cgroup")
    if "docker" in cgroup:
        return "docker"
    if "lxc" in cgroup:
        return "lxc"
    if "Microsoft" in read_file("/proc/sys/kernel/osrelease"):
        return "wsl"
    dmi = (read_file("/sys/class/dmi/id/product_name") + " " +
           read_file("/sys/class/dmi/id/sys_vendor") + " " +
           read_file("/sys/class/dmi/id/bios_vendor")).lower()
    for key, name in (("kvm", "kvm"), ("qemu", "kvm"), ("vmware", "vmware"),
                      ("virtualbox", "vbox"), ("xen", "xen"), ("hyper-v", "hyperv"),
                      ("microsoft corporation", "hyperv"), ("amazon ec2", "kvm"),
                      ("google compute", "kvm"), ("alibaba cloud", "kvm"),
                      ("openstack", "kvm"), ("bochs", "bochs"), ("parallels", "parallels")):
        if key in dmi:
            return name
    if os.path.exists("/proc/xen"):
        return "xen"
    if " hypervisor" in read_file("/proc/cpuinfo"):
        return "vm"
    return "dedi"


def detect_country():
    """识别服务器所在国家（ISO 两位代码，小写）"""
    try:
        txt = http_get("https://www.cloudflare.com/cdn-cgi/trace")
        m = re.search(r"^loc=([A-Z]{2})$", txt, re.M)
        if m and m.group(1) not in ("XX", "T1"):
            return m.group(1).lower()
    except Exception:
        pass
    for url in ("http://ip-api.com/line/?fields=countryCode", "https://ipinfo.io/country"):
        try:
            cc = http_get(url).strip()
            if re.fullmatch(r"[A-Za-z]{2}", cc):
                return cc.lower()
        except Exception:
            pass
    return ""


def can_connect(family, addr, port=53, timeout=3):
    s = socket.socket(family, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect((addr, port))
        return True
    except Exception:
        return False
    finally:
        s.close()


def detect_proto():
    """识别网络协议栈：4 / 6 / 46（双栈）"""
    v4 = can_connect(socket.AF_INET, "1.1.1.1") or can_connect(socket.AF_INET, "8.8.8.8")
    v6 = False
    if socket.has_ipv6:
        v6 = can_connect(socket.AF_INET6, "2606:4700:4700::1111") or \
             can_connect(socket.AF_INET6, "2001:4860:4860::8888")
    return ("4" if v4 else "") + ("6" if v6 else "")


def os_name():
    txt = read_file("/etc/os-release")
    m = re.search(r'^PRETTY_NAME="?([^"\n]*)"?', txt, re.M)
    return m.group(1) if m else sys.platform


# ARM 处理器：(厂商编号, 型号编号) -> 名称，lscpu 不可用时兜底
ARM_PARTS = {
    ("0x41", "0xd03"): "Cortex-A53", ("0x41", "0xd05"): "Cortex-A55", ("0x41", "0xd07"): "Cortex-A57",
    ("0x41", "0xd08"): "Cortex-A72", ("0x41", "0xd0b"): "Cortex-A76", ("0x41", "0xd0c"): "Neoverse-N1",
    ("0x41", "0xd40"): "Neoverse-V1", ("0x41", "0xd49"): "Neoverse-N2", ("0x41", "0xd4f"): "Neoverse-V2",
    ("0x48", "0xd01"): "Kunpeng-920", ("0xc0", "0xac3"): "Ampere-1", ("0xc0", "0xac4"): "Ampere-1a",
}


def cpu_model():
    """处理器型号：x86 读 model name；ARM 依次尝试 lscpu、型号编号对照、Hardware 字段"""
    info = read_file("/proc/cpuinfo")
    m = re.search(r"^model name\s*:\s*(.+)$", info, re.M)
    if m:
        return re.sub(r"\s+", " ", m.group(1)).strip()
    try:
        out = os.popen("LC_ALL=C lscpu 2>/dev/null").read()
        name = re.search(r"^Model name:\s*(.+)$", out, re.M)
        if name and name.group(1).strip() not in ("-", ""):
            vendor = re.search(r"^Vendor ID:\s*(.+)$", out, re.M)
            v = vendor.group(1).strip() if vendor else ""
            return (v + " " + name.group(1).strip()).strip() if v and v not in name.group(1) else name.group(1).strip()
    except Exception:
        pass
    imp = re.search(r"^CPU implementer\s*:\s*(\S+)$", info, re.M)
    part = re.search(r"^CPU part\s*:\s*(\S+)$", info, re.M)
    if imp and part and (imp.group(1), part.group(1)) in ARM_PARTS:
        return ARM_PARTS[(imp.group(1), part.group(1))]
    for key in ("Hardware", "Processor", "cpu model"):
        m = re.search(r"^%s\s*:\s*(.+)$" % key, info, re.M)
        if m:
            return m.group(1).strip()
    return read_file("/sys/firmware/devicetree/base/model").strip("\x00 \n")


def meminfo():
    info = {}
    for line in read_file("/proc/meminfo").splitlines():
        parts = line.split()
        if len(parts) >= 2:
            info[parts[0].rstrip(":")] = int(parts[1]) * 1024
    total = info.get("MemTotal", 0)
    avail = info.get("MemAvailable")
    if avail is None:
        avail = info.get("MemFree", 0) + info.get("Buffers", 0) + info.get("Cached", 0)
    swap_total = info.get("SwapTotal", 0)
    swap_used = swap_total - info.get("SwapFree", 0)
    return total, total - avail, swap_total, swap_used


def disk_usage():
    total = used = 0
    seen = set()
    for line in read_file("/proc/mounts").splitlines():
        parts = line.split()
        if len(parts) < 3 or parts[2] not in DISK_FS or parts[0] in seen:
            continue
        seen.add(parts[0])
        try:
            st = os.statvfs(parts[1])
        except Exception:
            continue
        total += st.f_blocks * st.f_frsize
        used += (st.f_blocks - st.f_bfree) * st.f_frsize
    return total, used


# ---------------------------------------------------------------- 动态采集

def cpu_times():
    fields = read_file("/proc/stat").splitlines()[0].split()[1:]
    vals = [int(x) for x in fields[:8]]
    return sum(vals), vals[3] + vals[4]


def net_bytes():
    rx = tx = 0
    for line in read_file("/proc/net/dev").splitlines()[2:]:
        name, _, data = line.partition(":")
        name = name.strip()
        if not name or name.startswith(NET_EXCLUDE):
            continue
        d = data.split()
        rx += int(d[0])
        tx += int(d[8])
    return rx, tx


def disk_io():
    r = w = 0
    for line in read_file("/proc/diskstats").splitlines():
        d = line.split()
        if len(d) > 9 and DISK_DEV_RE.match(d[2]):
            r += int(d[5]) * 512
            w += int(d[9]) * 512
    return r, w


def count_conn():
    def cnt(*paths):
        n = 0
        for p in paths:
            n += max(0, len(read_file(p).splitlines()) - 1)
        return n
    return cnt("/proc/net/tcp", "/proc/net/tcp6"), cnt("/proc/net/udp", "/proc/net/udp6")


def proc_thread():
    procs = sum(1 for x in os.listdir("/proc") if x.isdigit())
    try:
        threads = int(read_file("/proc/loadavg").split()[3].split("/")[1])
    except Exception:
        threads = 0
    return procs, threads


def uptime():
    try:
        return int(float(read_file("/proc/uptime").split()[0]))
    except Exception:
        return 0


# ---------------------------------------------------------------- 流量累计（月流量 / 总流量）

class Traffic:
    """按账单日累计月流量，重启后计数器归零也能正确累加"""

    def __init__(self, reset_day):
        self.reset_day = max(1, min(28, int(reset_day or 1)))
        self.lock = threading.Lock()
        rx, tx = net_bytes()
        st = {}
        try:
            with open(STATE_FILE) as f:
                st = json.load(f)
        except Exception:
            pass
        self.period = st.get("p", self.cur_period())
        self.last_rx = st.get("lr", rx)
        self.last_tx = st.get("lt", tx)
        self.month_rx = st.get("mr", 0)
        self.month_tx = st.get("mt", 0)
        # 首次安装时总流量以开机以来的网卡计数为起点
        self.total_rx = st.get("tr", rx)
        self.total_tx = st.get("tt", tx)
        self.update(rx, tx)
        self.save()

    def cur_period(self):
        t = date.today()
        y, m = t.year, t.month
        if t.day < self.reset_day:
            y, m = (y - 1, 12) if m == 1 else (y, m - 1)
        return "%d-%02d" % (y, m)

    def update(self, rx, tx):
        with self.lock:
            drx = rx - self.last_rx if rx >= self.last_rx else rx
            dtx = tx - self.last_tx if tx >= self.last_tx else tx
            self.last_rx, self.last_tx = rx, tx
            p = self.cur_period()
            if p != self.period:
                self.period = p
                self.month_rx = self.month_tx = 0
            self.month_rx += drx
            self.month_tx += dtx
            self.total_rx += drx
            self.total_tx += dtx

    def save(self):
        with self.lock:
            data = {"p": self.period, "lr": self.last_rx, "lt": self.last_tx,
                    "mr": self.month_rx, "mt": self.month_tx,
                    "tr": self.total_rx, "tt": self.total_tx}
        tmp = STATE_FILE + ".tmp"
        try:
            with open(tmp, "w") as f:
                json.dump(data, f)
            os.replace(tmp, STATE_FILE)
        except Exception as e:
            log("保存流量状态失败:", e)


# ---------------------------------------------------------------- 三网延迟 / 丢包

class Pinger:
    """TCP 握手测延迟，低频探测（默认 60 秒一次）以节省流量"""

    def __init__(self):
        self.targets = {}
        self.interval = 60
        self.window = 10
        self.data = {}
        self.lock = threading.Lock()
        self.started = False

    def configure(self, targets, interval, window):
        with self.lock:
            self.targets = dict(targets or {})
            self.interval = max(5, int(interval or 60))
            if int(window or 10) != self.window:
                self.window = max(5, int(window or 10))
                self.data = {}
        if not self.started:
            self.started = True
            threading.Thread(target=self.loop, daemon=True).start()

    @staticmethod
    def tcping(target, timeout=2):
        host, _, port = target.rpartition(":")
        host = host.strip("[]")
        try:
            addr = socket.getaddrinfo(host, int(port), 0, socket.SOCK_STREAM)[0]
        except Exception:
            return None
        s = socket.socket(addr[0], socket.SOCK_STREAM)
        s.settimeout(timeout)
        t = time.time()
        try:
            s.connect(addr[4])
            return int((time.time() - t) * 1000)
        except Exception:
            return None
        finally:
            s.close()

    def loop(self):
        while True:
            with self.lock:
                targets = list(self.targets.items())
                interval = self.interval
            for key, target in targets:
                ms = self.tcping(target)
                with self.lock:
                    q = self.data.get(key)
                    if q is None or q.maxlen != self.window:
                        q = self.data[key] = deque(maxlen=self.window)
                    q.append(ms)
            time.sleep(interval)

    def result(self, key):
        """返回 [延迟ms, 丢包率%]，无数据时延迟为 -1"""
        with self.lock:
            q = list(self.data.get(key) or [])
        if not q:
            return [-1, 0]
        ok = [x for x in q if x is not None]
        loss = round((len(q) - len(ok)) * 100 / len(q))
        recent = ok[-3:]
        ms = round(sum(recent) / len(recent)) if recent else -1
        return [ms, loss]


# ---------------------------------------------------------------- 被主控删除后自行卸载

def self_uninstall():
    """删除服务、开机任务和安装目录。卸载脚本放到服务之外运行，避免停止服务时被一起结束"""
    log("本节点已在主控中删除，开始自行卸载")
    d = BASE_DIR
    script = """sleep 2
if command -v systemctl >/dev/null 2>&1; then
  systemctl disable --now probe-agent >/dev/null 2>&1
  rm -f /etc/systemd/system/probe-agent.service
  systemctl daemon-reload >/dev/null 2>&1
fi
if [ -f /etc/init.d/probe-agent ]; then
  rc-service probe-agent stop >/dev/null 2>&1; rc-update del probe-agent default >/dev/null 2>&1
  rm -f /etc/init.d/probe-agent
fi
if crontab -l 2>/dev/null | grep -q '%(d)s/'; then
  crontab -l 2>/dev/null | grep -v '%(d)s/' | crontab -
fi
pkill -f '%(d)s/agent.py'
rm -rf '%(d)s'
""" % {"d": d}
    import shutil
    import subprocess
    if shutil.which("systemd-run") and os.path.isdir("/run/systemd/system"):
        cmd = ["systemd-run", "--quiet", "--unit", "probe-agent-remove-%d" % time.time(), "/bin/sh", "-c", script]
    else:
        cmd = ["/bin/sh", "-c", script]
    subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)
    while True:   # 等待被卸载脚本结束
        time.sleep(60)


# ---------------------------------------------------------------- 主循环

class Agent:
    def __init__(self, cfg):
        self.cfg = cfg
        self.traffic = Traffic(cfg.get("reset_day", 1))
        self.pinger = Pinger()
        self.static = None
        self.static_ts = 0
        self.geo = {"cc": "", "proto": "", "ts": 0}
        self.prev_cpu = cpu_times()
        self.prev_net = net_bytes()
        self.prev_io = disk_io()
        self.prev_t = time.time()
        self.last_save = time.time()
        self.failed_update = None

    def refresh_geo(self):
        # 国家与协议栈每 6 小时检测一次
        if time.time() - self.geo["ts"] > 21600 or not self.geo["cc"]:
            if time.time() - self.geo["ts"] > 300:
                self.geo = {"cc": detect_country() or self.geo["cc"],
                            "proto": detect_proto() or self.geo["proto"], "ts": time.time()}

    def build_static(self):
        self.refresh_geo()
        mem_total, _, swap_total, _ = meminfo()
        disk_total, _ = disk_usage()
        return ["s", self.cfg.get("name") or socket.gethostname(), detect_virt(),
                self.geo["cc"], self.geo["proto"], os.cpu_count() or 1,
                mem_total, swap_total, disk_total, os_name(), os.uname().machine, cpu_model()]

    def build_dynamic(self):
        now = time.time()
        dt = max(0.001, now - self.prev_t)
        self.prev_t = now

        total, idle = cpu_times()
        pt, pi = self.prev_cpu
        self.prev_cpu = (total, idle)
        cpu = 0.0 if total == pt else round((1 - (idle - pi) / (total - pt)) * 100, 1)

        rx, tx = net_bytes()
        prx, ptx = self.prev_net
        self.prev_net = (rx, tx)
        nrx = int(max(0, rx - prx) / dt)
        ntx = int(max(0, tx - ptx) / dt)
        self.traffic.update(rx, tx)

        r, w = disk_io()
        pr, pw = self.prev_io
        self.prev_io = (r, w)

        _, mem_used, _, swap_used = meminfo()
        _, disk_used = disk_usage()
        tcp, udp = count_conn()
        procs, threads = proc_thread()
        tr = self.traffic
        d = ["d", max(0.0, min(100.0, cpu)), round(os.getloadavg()[0], 2), nrx, ntx,
             tr.total_rx, tr.total_tx, tr.month_rx, tr.month_tx,
             mem_used, swap_used, disk_used,
             int(max(0, r - pr) / dt), int(max(0, w - pw) / dt),
             tcp, udp, procs, threads, uptime()]
        for k in ("cu", "ct", "cm"):
            d.extend(self.pinger.result(k))

        if now - self.last_save > 60:
            self.last_save = now
            self.traffic.save()
        return d

    def self_update(self, host, port, av):
        """从主控下载新版 agent.py，校验后替换自身并原地重启（PID 不变，兼容 systemd/OpenRC/nohup）"""
        log("发现新版客户端，开始更新")
        try:
            sock = socket.create_connection((host, port), timeout=30)
            try:
                auth = {"t": self.cfg["token"], "id": self.cfg["id"], "up": 1}
                sock.sendall((json.dumps(auth) + "\n").encode())
                resp = json.loads(sock.makefile("rb").readline(4 << 20).decode() or "{}")
            finally:
                sock.close()
            data = (resp.get("agent") or "").encode("utf-8")
            if hashlib.sha256(data).hexdigest() != av:
                raise ValueError("校验失败")
            path = os.path.abspath(__file__)
            with open(path + ".tmp", "wb") as f:
                f.write(data)
            os.replace(path + ".tmp", path)
        except Exception as e:
            log("客户端更新失败:", e)
            self.failed_update = av   # 同一版本不再重试，继续正常上报
            return
        log("客户端已更新，重启")
        self.traffic.save()
        os.execv(sys.executable, [sys.executable, "-u", os.path.abspath(__file__)])

    def run_once(self):
        host, port = self.cfg["server"], int(self.cfg.get("port", 35688))
        log("连接服务端 %s:%s" % (host, port))
        sock = socket.create_connection((host, port), timeout=10)
        try:
            f = sock.makefile("rb")
            auth = {"t": self.cfg["token"], "id": self.cfg["id"], "v": 1, "sv": SELF_SHA}
            sock.sendall((json.dumps(auth, separators=(",", ":")) + "\n").encode())
            resp = json.loads(f.readline(65536).decode() or "{}")
            if not resp.get("ok"):
                if resp.get("msg") == "removed":
                    self_uninstall()
                log("认证失败:", resp.get("msg", "未知错误"))
                time.sleep(60)
                return
            av = resp.get("av")
            if av and av != SELF_SHA and av != self.failed_update:
                sock.close()
                self.self_update(host, port, av)
                return
            interval = max(1, int(resp.get("i", 3)))
            self.pinger.configure(resp.get("p"), resp.get("pi"), resp.get("pw"))
            log("已连接，上报间隔 %ss" % interval)
            self.static = None
            while True:
                t0 = time.time()
                msgs = []
                # 静态信息每 10 分钟重新采集一次，只有变化时才发送
                if self.static is None or t0 - self.static_ts > 600:
                    st = self.build_static()
                    self.static_ts = t0
                    if st != self.static:
                        self.static = st
                        msgs.append(st)
                msgs.append(self.build_dynamic())
                payload = "".join(json.dumps(m, separators=(",", ":"), ensure_ascii=False) + "\n"
                                  for m in msgs)
                sock.sendall(payload.encode("utf-8"))
                time.sleep(max(0.2, interval - (time.time() - t0)))
        finally:
            sock.close()

    def run(self):
        delay = 3
        while True:
            start = time.time()
            try:
                self.run_once()
            except Exception as e:
                log("连接中断:", e)
            self.traffic.save()
            delay = 3 if time.time() - start > 60 else min(delay * 2, 60)
            time.sleep(delay)


def main():
    try:
        with open(CONFIG_FILE, encoding="utf-8") as f:
            cfg = json.load(f)
    except Exception as e:
        log("读取配置失败 %s: %s" % (CONFIG_FILE, e))
        sys.exit(1)
    for k in ("server", "token", "id"):
        if not cfg.get(k):
            log("配置缺少字段:", k)
            sys.exit(1)
    agent = Agent(cfg)

    def on_exit(*_):
        agent.traffic.save()
        sys.exit(0)

    signal.signal(signal.SIGTERM, on_exit)
    signal.signal(signal.SIGINT, on_exit)
    agent.run()


if __name__ == "__main__":
    main()
