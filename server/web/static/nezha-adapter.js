// 数据适配层：把主控的 json/stats.json、json/ping24h.json 转换为哪吒 v0 前端使用的数据格式，
// 并用定时拉取模拟原版的 WebSocket 实时通道（原版每 2 秒推送一次）
(function () {
    var POLL_MS = 2000;
    var idOf = {}, hexOf = {}, nameOf = {}, nextId = 1;
    var pageVersion = '';
    var p24 = { at: 0, data: null };

    // 主控节点 ID（十六进制字符串）映射为哪吒使用的数字 ID
    function numId(hex) {
        if (!idOf[hex]) {
            idOf[hex] = nextId++;
            hexOf[idOf[hex]] = hex;
        }
        return idOf[hex];
    }

    // cpu_info / custom 由服务端做了 HTML 转义，还原为纯文本（页面由 Vue 负责转义）
    function unesc(s) {
        var t = document.createElement('textarea');
        t.innerHTML = String(s || '');
        return t.value;
    }

    // "Debian GNU/Linux 12 (bookworm)" -> ["debian", "12"]；Windows 保留完整名称以显示 Windows 图标
    function platformOf(os) {
        if (/windows/i.test(os)) return [/^microsoft/i.test(os) ? os : 'Microsoft ' + os, ''];
        var lower = os.toLowerCase(), name = lower.split(/[\s/]/)[0] || 'linux';
        var known = [['red hat', 'redhat'], ['linux mint', 'linuxmint'], ['kali', 'kali-linux'], ['pop!_os', 'pop-os'],
            ['rocky', 'rocky'], ['alma', 'almalinux'], ['amazon', 'amazon'], ['arch', 'arch'], ['opensuse', 'opensuse']];
        for (var i = 0; i < known.length; i++) {
            if (lower.indexOf(known[i][0]) === 0) { name = known[i][1]; break; }
        }
        var ver = (os.match(/\d+(\.\d+)*/) || [''])[0];
        return [name, ver];
    }

    function convert(data) {
        var now = (Number(data.updated) || Date.now() / 1000) * 1000;
        var servers = (data.servers || []).map(function (it, idx) {
            var id = numId(String(it.id || it.name || idx));
            var online = Boolean(it.online4 || it.online6);
            // custom 形如 "系统: Debian GNU/Linux 12 (bookworm) (x86_64)"
            var sys = unesc(it.custom).replace(/^系统:\s*/, '');
            var m = sys.match(/^(.*)\s+\(([^()]*)\)$/);
            var os = m ? m[1] : sys, arch = m ? m[2] : '';
            var plat = platformOf(os);
            // cpu_info 形如 "型号 | 2 核"
            var cpu = unesc(it.cpu_info).match(/^(.*)\s*\|\s*(\d+)\s*核$/);
            var virt = String(it.type || '').toLowerCase();
            var last = it.last_active || (online ? Number(data.updated) : 0);
            nameOf[id] = it.name;
            return {
                ID: id,
                Name: it.name,
                Tag: '',
                DisplayIndex: 0,
                LastActive: new Date((last || 0) * 1000).toISOString(),
                nzOnline: online,
                live: online,
                Host: {
                    Platform: plat[0],
                    PlatformVersion: plat[1],
                    CPU: cpu ? [cpu[1].trim() + ' ' + cpu[2] + ' Virtual Core'] : [unesc(it.cpu_info)],
                    GPU: null,
                    MemTotal: (it.memory_total || 0) * 1024,
                    DiskTotal: (it.hdd_total || 0) * 1048576,
                    SwapTotal: (it.swap_total || 0) * 1024,
                    Arch: arch,
                    Virtualization: virt === '-' ? '' : virt,
                    BootTime: it.boot_time || 0,
                    CountryCode: String(it.location || '').toLowerCase(),
                    Version: data.version || ''
                },
                State: {
                    CPU: Number(it.cpu) || 0,
                    MemUsed: (it.memory_used || 0) * 1024,
                    SwapUsed: (it.swap_used || 0) * 1024,
                    DiskUsed: (it.hdd_used || 0) * 1048576,
                    NetInTransfer: it.network_in || 0,
                    NetOutTransfer: it.network_out || 0,
                    NetInSpeed: online ? it.network_rx || 0 : 0,
                    NetOutSpeed: online ? it.network_tx || 0 : 0,
                    Uptime: online && it.boot_time ? Math.max(0, Math.round(now / 1000 - it.boot_time)) : 0,
                    Load1: Number(it.load_1) || 0,
                    Load5: Number(it.load_5) || 0,
                    Load15: Number(it.load_15) || 0,
                    TcpConnCount: it.tcp_count || 0,
                    UdpConnCount: it.udp_count || 0,
                    ProcessCount: it.process_count || 0,
                    Temperatures: null
                }
            };
        });
        return { now: now, servers: servers };
    }

    window.nzFetchStats = function () {
        return fetch('/json/stats.json', { cache: 'no-store' }).then(function (r) {
            if (!r.ok) throw new Error('HTTP ' + r.status);
            return r.json();
        }).then(function (data) {
            // 主控更新后版本号变化，自动刷新页面加载新前端
            if (data.version) {
                if (!pageVersion) pageVersion = data.version;
                else if (pageVersion !== data.version) setTimeout(function () { location.reload(); }, 1000);
                var v = document.getElementById('nzVersion');
                if (v) v.textContent = data.version;
            }
            if (data.title) {
                document.title = data.title;
                var b = document.getElementById('nzBrand');
                if (b) b.textContent = data.title;
            }
            return convert(data);
        });
    };

    // 首屏数据就绪后再启动页面；拉取失败时以空列表启动，实时通道会继续重试
    window.nzBoot = function (start) {
        window.nzFetchStats().then(function (d) {
            start(d.servers);
        }, function () {
            start([]);
        });
    };

    function loadPing24h() {
        if (p24.data && Date.now() - p24.at < 60000) return Promise.resolve(p24.data);
        return fetch('/json/ping24h.json', { cache: 'no-store' }).then(function (r) {
            if (!r.ok) throw new Error('HTTP ' + r.status);
            return r.json();
        }).then(function (d) {
            p24.data = d;
            p24.at = Date.now();
            return d;
        });
    }

    // 模拟 /api/v1/monitor/{id}：三网 24 小时历史，每行 [格起始时间, 联通丢包%, 联通延迟ms, 电信.., .., 移动.., ..]，
    // 无数据为 -1；整格丢包（延迟 -1、丢包 >= 0）按哪吒的约定记为延迟 0
    window.nzMonitor = function (id) {
        return loadPing24h().then(function (d) {
            var rows = (d.nodes || {})[hexOf[id]] || [];
            var lines = [['电信', 3], ['联通', 1], ['移动', 5]];
            var result = rows.length ? lines.map(function (ln, k) {
                var created = [], delay = [];
                rows.forEach(function (r) {
                    var loss = r[ln[1]], ms = r[ln[1] + 1];
                    if (loss < 0 && ms < 0) return;
                    created.push(r[0] * 1000);
                    delay.push(ms >= 0 ? ms : 0);
                });
                return {
                    monitor_id: k + 1, server_id: id, monitor_name: ln[0], server_name: nameOf[id] || '',
                    created_at: created, avg_delay: delay
                };
            }) : [];
            return { result: result, server_name: nameOf[id] || '' };
        });
    };

    // 与 WebSocket 相同的回调接口：首次成功触发 onopen，之后每次数据触发 onmessage，失败触发 onclose
    window.NzSocket = function () {
        var self = this, timer = null, opened = false, closed = false;

        function tick() {
            if (closed) return;
            // 页面不可见时不拉取，节省流量
            if (document.hidden) {
                timer = setTimeout(tick, POLL_MS);
                return;
            }
            window.nzFetchStats().then(function (d) {
                if (closed) return;
                if (!opened) {
                    opened = true;
                    if (self.onopen) self.onopen({});
                }
                if (self.onmessage) self.onmessage({ data: JSON.stringify(d) });
                timer = setTimeout(tick, POLL_MS);
            }, function () {
                self.close();
            });
        }

        this.close = function () {
            if (closed) return;
            closed = true;
            clearTimeout(timer);
            if (self.onclose) self.onclose({});
        };
        setTimeout(tick, 0);
    };
})();
