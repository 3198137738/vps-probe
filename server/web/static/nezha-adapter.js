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

    // 页面中的品牌名、版本号（主题模板里可能出现多处）
    function setText(kind, text) {
        var els = document.querySelectorAll('[data-nz="' + kind + '"]');
        for (var i = 0; i < els.length; i++) {
            if (els[i].textContent !== text) els[i].textContent = text;
        }
    }

    // 换用新的背景图：选择器比 glass.css 更具体，确保覆盖；带版本号避开浏览器缓存
    var lastBg = null;
    function applyBackground(ver) {
        var style = document.getElementById('nzBackground');
        if (!style) {
            style = document.createElement('style');
            style.id = 'nzBackground';
            document.head.appendChild(style);
        }
        style.textContent = ver === 'none'
            // 无背景：显示与主题明暗对应的纯色
            ? 'html body[theme]::before{background-image:none !important}' +
              'html body[theme="light"]::before{background-color:#eef1f5 !important}' +
              'html body[theme="dark"]::before{background-color:#14161d !important}'
            : 'html body[theme]::before{background-image:url(/background?v=' + encodeURIComponent(ver) + ') !important}';
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
                setText('version', data.version);
            }
            if (data.title) {
                document.title = data.title;
                setText('brand', data.title);
            }
            // 背景图在主控上更换后（网页、probe 或接口），所有已打开的页面立即换图
            if (data.bg !== undefined && data.bg !== lastBg) {
                if (lastBg !== null || data.bg === 'none') applyBackground(data.bg || 'default');
                lastBg = data.bg;
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
        // 数据有缓存时也延后到下一轮事件循环返回（与原版网络请求的时序一致）：
        // 主题在点击时请求图表数据，需等 Bootstrap 展开详情区后再绘制，否则图表宽度为 0
        return loadPing24h().then(function (d) {
            return new Promise(function (resolve) { setTimeout(function () { resolve(d); }, 0); });
        }).then(function (d) {
            var rows = (d.nodes || {})[hexOf[id]] || [];
            var lines = [['电信网络', 3], ['移动网络', 5], ['联通网络', 1]];
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

    // 图例显示的平均延迟（ms，保留两位小数）：只统计有效延迟，整格丢包（0）不计入
    window.nzAvgDelay = function (delays) {
        var ok = (delays || []).filter(function (v) { return v > 0 && v < 1000; });
        if (!ok.length) return '-';
        return (ok.reduce(function (a, b) { return a + b; }, 0) / ok.length).toFixed(2);
    };

    // 与 WebSocket 相同的回调接口：首次成功触发 onopen，之后每次数据触发 onmessage，失败触发 onclose。
    // 同一时间只保留最新的一个连接，避免主题脚本重连时重复拉取
    var current = null;
    window.NzSocket = function () {
        var self = this, timer = null, opened = false, closed = false;
        if (current) current.stop();
        current = this;
        this.readyState = 0;

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
                    self.readyState = 1;
                    if (self.onopen) self.onopen({});
                }
                if (self.onmessage) self.onmessage({ data: JSON.stringify(d) });
                timer = setTimeout(tick, POLL_MS);
            }, function () {
                self.close();
            });
        }

        // 被新连接取代：静默停止
        this.stop = function () {
            closed = true;
            self.readyState = 3;
            clearTimeout(timer);
        };
        this.close = function () {
            if (closed) return;
            self.stop();
            if (self.onclose) self.onclose({});
        };
        setTimeout(tick, 0);
    };

    // 主题切换只提供本项目包含的主题
    if (typeof mixinsVue !== 'undefined') {
        mixinsVue.data.adaptedTemplates = mixinsVue.data.adaptedTemplates.filter(function (t) {
            return t.key === 'default' || t.key === 'server-status';
        });
    }

    // ServerStatus 主题默认开启半透明（毛玻璃）模式；之前访问过的浏览器也切换一次，之后以访客的选择为准
    try {
        if (localStorage.getItem('nzGlassDefault') !== '1') {
            localStorage.setItem('semiTransparent', 'true');
            localStorage.setItem('nzGlassDefault', '1');
        }
    } catch (e) {}

    // 背景设置（ServerStatus 主题工具栏按钮）：上传图片 / 恢复默认背景 / 无背景。需主控 Token，首次输入后保存在本浏览器
    function backgroundRequest(mode, body) {
        var token = localStorage.getItem('nzToken') || prompt('请输入主控 Token（在主控上运行 probe，选择「8. 查看 Token 与添加命令」）');
        if (!token) return;
        token = token.trim();
        var q = 'action=background&token=' + encodeURIComponent(token) + (mode ? '&mode=' + mode : '');
        fetch('/api/admin?' + q, { method: 'POST', body: body || '' })
            .then(function (r) {
                if (r.status === 403) throw new Error('Token 错误');
                return r.json();
            })
            .then(function (d) {
                if (!d.ok) throw new Error(d.msg || '操作失败');
                localStorage.setItem('nzToken', token);
                lastBg = mode === 'none' ? 'none' : (mode === 'default' ? '' : 't' + Date.now());
                applyBackground(mode === 'none' ? 'none' : (mode === 'default' ? 'default' : lastBg));
            })
            .catch(function (e) {
                if (e.message === 'Token 错误') localStorage.removeItem('nzToken');
                alert('背景设置失败：' + e.message);
            });
    }

    function chooseImage() {
        var input = document.createElement('input');
        input.type = 'file';
        input.accept = 'image/jpeg,image/png,image/webp,image/gif';
        input.onchange = function () {
            var file = input.files[0];
            if (!file) return;
            if (file.size > 10 * 1024 * 1024) return alert('图片不能超过 10MB');
            backgroundRequest('', file);
        };
        input.click();
    }

    function closeBackgroundMenu(e) {
        var m = document.getElementById('nzBgMenu');
        if (e && m && m.contains(e.target)) return;   // 点击的是菜单项，由菜单项自己处理
        if (m) m.remove();
        document.removeEventListener('click', closeBackgroundMenu, true);
    }

    window.nzUploadBackground = function (ev) {
        if (document.getElementById('nzBgMenu')) return closeBackgroundMenu();
        var btn = (ev || window.event || {}).target;
        var r = btn && btn.getBoundingClientRect ? btn.getBoundingClientRect() : { left: window.innerWidth - 60, top: window.innerHeight - 120 };
        var menu = document.createElement('div');
        menu.id = 'nzBgMenu';
        menu.className = 'nz-bg-menu';
        menu.style.right = Math.max(8, window.innerWidth - r.left + 8) + 'px';
        menu.style.bottom = Math.max(8, window.innerHeight - r.bottom) + 'px';
        [['bi-upload', '上传图片', chooseImage],
         ['bi-arrow-counterclockwise', '恢复默认背景', function () { backgroundRequest('default'); }],
         ['bi-slash-circle', '无背景', function () { backgroundRequest('none'); }]].forEach(function (it) {
            var a = document.createElement('a');
            a.innerHTML = '<i class="bi ' + it[0] + '"></i>' + it[1];
            a.onclick = function (e) { e.stopPropagation(); closeBackgroundMenu(); it[2](); };
            menu.appendChild(a);
        });
        document.body.appendChild(menu);
        // 点击菜单以外的位置关闭
        setTimeout(function () { document.addEventListener('click', closeBackgroundMenu, true); }, 0);
    };
})();
