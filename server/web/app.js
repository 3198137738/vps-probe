(function () {
  'use strict';

  var INTERVAL = 3000;            // 刷新间隔（毫秒）
  var expanded = {};              // 已展开详情的节点
  var timer = null;
  var lastData = null;            // 最近一次数据，展开详情时直接重绘不再请求

  // ---------------------------------------------------------- 格式化
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  // 流量：13.1G / 1.25T
  function traffic(b) {
    var g = b / 1073741824;
    return g >= 1024 ? (g / 1024).toFixed(2) + 'T' : g.toFixed(1) + 'G';
  }
  // 网速：0.6K / 45.8K / 1.2M
  function speed(b) {
    var k = b / 1024;
    if (k >= 1024 * 1024) return (k / 1048576).toFixed(1) + 'G';
    if (k >= 1024) return (k / 1024).toFixed(1) + 'M';
    return k.toFixed(1) + 'K';
  }
  // 容量：255.0 M / 4.33 G
  function size(b, digits) {
    var units = ['B', 'K', 'M', 'G', 'T', 'P'], i = 0;
    while (b >= 1024 && i < units.length - 1) { b /= 1024; i++; }
    return (i === 0 ? b : b.toFixed(digits)) + ' ' + units[i];
  }
  function ioSpeed(b) {
    if (b >= 1048576) return (b / 1048576).toFixed(1) + 'M';
    return Math.round(b / 1024) + 'K';
  }
  function uptime(s) {
    if (s >= 86400) return Math.floor(s / 86400) + ' 天';
    if (s >= 3600) return Math.floor(s / 3600) + ' 小时';
    return Math.floor(s / 60) + ' 分钟';
  }
  function pct(used, total) {
    return total > 0 ? Math.round(used * 100 / total) : 0;
  }
  function protoText(p) {
    if (p === '46') return '双栈';
    if (p === '6') return 'IPv6';
    return 'IPv4';
  }

  // ---------------------------------------------------------- 渲染
  function bar(v) {
    v = Math.max(0, Math.min(100, Math.round(v)));
    var cls = v >= 90 ? ' danger' : v >= 70 ? ' warn' : '';
    if (v >= 100) cls += ' full';
    return '<div class="progress"><div class="bar' + cls + '" style="width:' + v + '%"></div><span>' + v + '%</span></div>';
  }
  function flag(cc) {
    if (!cc) return '-';
    return '<img class="flag" loading="lazy" src="https://flagcdn.com/24x18/' + esc(cc) + '.png" ' +
      'alt="' + esc(cc) + '" title="' + esc(cc.toUpperCase()) + '" onerror="this.outerHTML=\'' + esc(cc) + '\'">';
  }
  // 三网分隔用的小电脑图标（内联 SVG，不额外请求）
  var PC = '<svg class="pc" viewBox="0 0 13 11"><rect x="1.5" y=".5" width="10" height="7" rx="1" fill="#222"/>' +
    '<rect x="2.5" y="1.5" width="8" height="5" fill="#dfe6ee"/><rect y="8" width="13" height="2.5" rx="1" fill="#222"/></svg>';
  function pingCell(d) {
    var l = [d[19], d[21], d[23]];
    var max = Math.max.apply(null, l);
    var cls = max >= 20 ? 'btn-danger' : max >= 10 ? 'btn-warning' : 'btn-success';
    return '<span class="btn ' + cls + '">' + l[0] + '%' + PC + l[1] + '%' + PC + l[2] + '%</span>';
  }
  function pingDetail(ms, loss) {
    return (ms < 0 ? '-' : ms + 'ms') + ' (' + loss + '%)';
  }

  function row(n, i) {
    var s = n.s, d = n.d, on = n.on && d;
    var stripe = i % 2 === 0 ? ' odd' : '';
    var h = '<tr class="node' + stripe + (on ? '' : ' offline') + '" data-id="' + esc(n.id) + '">';
    h += '<td class="c-proto"><span class="btn ' + (on ? 'btn-success' : 'btn-danger') + '">' + (on ? protoText(s[3]) : '离线') + '</span></td>';
    h += '<td class="c-month"><span class="btn ' + (on ? 'btn-success' : 'btn-default') + '">' +
      (d ? traffic(d[6]) + ' | ' + traffic(d[7]) : '-') + '</span></td>';
    h += '<td class="c-name">' + esc(s[0]) + '</td>';
    h += '<td class="c-virt">' + esc(s[1]) + '</td>';
    h += '<td class="c-loc">' + flag(s[2]) + '</td>';
    if (!on) {
      h += '<td class="c-up">-</td><td class="c-load">-</td><td class="c-net">-</td>';
      h += '<td class="c-total">' + (d ? traffic(d[4]) + ' | ' + traffic(d[5]) : '-') + '</td>';
      h += '<td class="c-bar">' + bar(0) + '</td><td class="c-bar">' + bar(0) + '</td><td class="c-bar">' + bar(0) + '</td>';
      h += '<td class="c-ping"><span class="btn btn-default">-</span></td></tr>';
      return h;
    }
    h += '<td class="c-up">' + uptime(d[17]) + '</td>';
    h += '<td class="c-load">' + Number(d[1]).toFixed(2) + '</td>';
    h += '<td class="c-net">' + speed(d[2]) + ' | ' + speed(d[3]) + '</td>';
    h += '<td class="c-total">' + traffic(d[4]) + ' | ' + traffic(d[5]) + '</td>';
    h += '<td class="c-bar">' + bar(d[0]) + '</td>';
    h += '<td class="c-bar">' + bar(pct(d[8], s[5])) + '</td>';
    h += '<td class="c-bar">' + bar(pct(d[10], s[7])) + '</td>';
    h += '<td class="c-ping">' + pingCell(d) + '</td></tr>';

    if (expanded[n.id]) {
      h += '<tr class="detail' + stripe + '"><td colspan="13">' +
        '<div>系统: ' + esc(s[8]) + ' (' + esc(s[9]) + ') | ' + s[4] + ' 核 ' + esc(s[10]) + '</div>' +
        '<div>内存|虚存: ' + size(d[8], 1) + ' / ' + size(s[5], 1) + ' | ' + size(d[9], 1) + ' / ' + size(s[6], 1) + '</div>' +
        '<div>硬盘|读写: ' + size(d[10], 2) + ' / ' + size(s[7], 2) + ' | ' + ioSpeed(d[11]) + ' / ' + ioSpeed(d[12]) + '</div>' +
        '<div>TCP/UDP/进/线: ' + d[13] + ' / ' + d[14] + ' / ' + d[15] + ' / ' + d[16] + '</div>' +
        '<div>CU/CT/CM: ' + pingDetail(d[18], d[19]) + ' / ' + pingDetail(d[20], d[21]) + ' / ' + pingDetail(d[22], d[23]) + '</div>' +
        '</td></tr>';
    }
    return h;
  }

  function render(data) {
    lastData = data;
    if (data.title) {
      document.title = data.title;
      document.getElementById('brand').textContent = data.title;
    }
    var nodes = data.nodes || [];
    var html = nodes.length ? nodes.map(row).join('') :
      '<tr><td colspan="13" class="loading">暂无节点，请在 VPS 上运行一键脚本添加</td></tr>';
    document.getElementById('tbody').innerHTML = html;
    lastUpdate = Date.now();
    updateFooter();
  }

  // 底部“最后更新”相对时间
  var lastUpdate = 0;
  function updateFooter() {
    if (!lastUpdate) return;
    var sec = Math.floor((Date.now() - lastUpdate) / 1000);
    var t = sec < 10 ? '几秒前' : sec < 60 ? sec + ' 秒前' : Math.floor(sec / 60) + ' 分钟前';
    document.getElementById('footer').textContent = '最后更新: ' + t + '.';
  }
  setInterval(updateFooter, 1000);

  // ---------------------------------------------------------- 数据拉取（页面隐藏时暂停，节省流量）
  function load() {
    var xhr = new XMLHttpRequest();
    xhr.open('GET', '/api/stats', true);
    xhr.timeout = 8000;
    xhr.onload = function () {
      if (xhr.status === 200) {
        try { render(JSON.parse(xhr.responseText)); } catch (e) { console.error(e); }
      }
    };
    xhr.send();
  }
  function start() {
    if (timer) return;
    load();
    timer = setInterval(load, INTERVAL);
  }
  function stop() {
    clearInterval(timer);
    timer = null;
  }
  document.addEventListener('visibilitychange', function () {
    document.hidden ? stop() : start();
  });

  // 点击节点展开 / 收起详情
  document.getElementById('tbody').addEventListener('click', function (e) {
    var tr = e.target.closest('tr.node');
    if (!tr || tr.classList.contains('offline')) return;
    var id = tr.getAttribute('data-id');
    expanded[id] = !expanded[id];
    if (lastData) render(lastData);
  });

  // ---------------------------------------------------------- 风格切换
  var dropdown = document.querySelector('.dropdown');
  document.getElementById('nav-theme').addEventListener('click', function (e) {
    e.preventDefault();
    e.stopPropagation();
    dropdown.classList.toggle('open');
  });
  document.addEventListener('click', function () { dropdown.classList.remove('open'); });
  function setTheme(t) {
    document.body.classList.toggle('dark', t === 'dark');
    try { localStorage.setItem('probe-theme', t); } catch (e) {}
  }
  document.getElementById('theme-menu').addEventListener('click', function (e) {
    var t = e.target.getAttribute('data-theme');
    if (t) { e.preventDefault(); setTheme(t); }
  });
  try { setTheme(localStorage.getItem('probe-theme') || 'light'); } catch (e) {}

  document.getElementById('nav-service').addEventListener('click', function (e) {
    e.preventDefault();
    alert('在 VPS 上执行服务端输出的一键安装命令，输入服务器名称即可添加节点。');
  });

  if (!document.hidden) start();
})();
