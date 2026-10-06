// serverstatus.js. big data boom today.
var error = 0;
var d = 0;
var server_status = new Array();
var page_version = "";

function timeSince(date) {
	if(date == 0)
		return "从未.";

	var seconds = Math.floor((new Date() - date) / 1000);
	var interval = Math.floor(seconds / 60);
	if (interval > 1)
		return interval + " 分钟前.";
	else
		return "几秒前.";
}

function bytesToSize(bytes, precision, si)
{
	var ret;
	si = typeof si !== 'undefined' ? si : 0;
	if(si != 0) {
		var megabyte = 1000 * 1000;
		var gigabyte = megabyte * 1000;
		var terabyte = gigabyte * 1000;
	} else {
		var megabyte = 1024 * 1024;
		var gigabyte = megabyte * 1024;
		var terabyte = gigabyte * 1024;
	}

	if ((bytes >= megabyte) && (bytes < gigabyte)) {
		ret = (bytes / megabyte).toFixed(precision) + ' M';

	} else if ((bytes >= gigabyte) && (bytes < terabyte)) {
		ret = (bytes / gigabyte).toFixed(precision) + ' G';

	} else if (bytes >= terabyte) {
		ret = (bytes / terabyte).toFixed(precision) + ' T';

	} else {
		return bytes + ' B';
	}
	return ret;
	/*if(si != 0) {
		return ret + 'B';
	} else {
		return ret + 'iB';
	}*/
}

// Unix 时间戳格式化为本地时间 YYYY-MM-DD HH:MM:SS
function formatTime(ts) {
	if (!ts)
		return "–";
	var t = new Date(ts * 1000);
	var p = function(n) { return (n < 10 ? "0" : "") + n; };
	return t.getFullYear() + "-" + p(t.getMonth() + 1) + "-" + p(t.getDate()) + " " +
		p(t.getHours()) + ":" + p(t.getMinutes()) + ":" + p(t.getSeconds());
}

// ---------------------------------------------------------------- 三网 24 小时丢包图
// 历史数据每分钟拉取一次；每行格式 [格起始时间, 联通丢包%, 联通延迟ms, 电信.., .., 移动.., ..]，无数据为 -1
var p24 = { at: 0, data: null };
var P24_LINES = ["联通", "电信", "移动"];

function loadPing24h() {
	if (Date.now() - p24.at < 60000)
		return;
	p24.at = Date.now();
	$.getJSON("json/ping24h.json", function(r) { p24.data = r; });
}

// 丢包率颜色：c0 0%，c1 0~10%，c2 10~30%，c3 >30%，cx 失联
function lossClass(loss) {
	return loss >= 100 ? "cx" : loss > 30 ? "c3" : loss > 10 ? "c2" : loss > 0 ? "c1" : "c0";
}

function fmtLoss(loss) {
	return (loss > 0 && loss < 10 ? loss.toFixed(1) : Math.round(loss)) + "%";
}

function fmtHM(ts) {
	var t = new Date(ts * 1000);
	return ("0" + t.getHours()).slice(-2) + ":" + ("0" + t.getMinutes()).slice(-2);
}

// 每条线路 24 小时平均 [丢包%, 延迟ms]，无数据为 -1
function p24Summary(rows) {
	var out = [];
	for (var k = 0; k < 3; k++) {
		var ls = 0, ln = 0, ms = 0, mn = 0;
		for (var j = 0; j < rows.length; j++) {
			if (rows[j][1 + 2 * k] >= 0) { ls += rows[j][1 + 2 * k]; ln++; }
			if (rows[j][2 + 2 * k] >= 0) { ms += rows[j][2 + 2 * k]; mn++; }
		}
		out.push([ln ? ls / ln : -1, mn ? Math.round(ms / mn) : -1]);
	}
	return out;
}

// 丢包图：每条线路一排柱子，颜色表示丢包率，高度表示延迟（350ms 及以上为满高）
function p24Chart(rows, sum) {
	var d = p24.data, slots = [];
	for (var j = 0; j < rows.length; j++)
		slots[(rows[j][0] - d.start) / d.step] = rows[j];
	var end = d.start + d.slots * d.step;
	var html = "<div class=\"p24\"><div class=\"p24-head\">三网 24 小时丢包<span>" +
		formatTime(d.start).slice(5, 16) + " - " + formatTime(Math.min(end, Date.now() / 1000)).slice(5, 16) + "　每 20 分钟一格</span></div>";
	for (var k = 0; k < 3; k++) {
		html += "<div class=\"p24-row\"><span class=\"p24-name\">" + P24_LINES[k] + "</span><div class=\"p24-bars\">";
		for (var i = 0; i < d.slots; i++) {
			var r = slots[i], loss = r ? r[1 + 2 * k] : -1, ms = r ? r[2 + 2 * k] : -1;
			if (loss < 0) {
				html += "<i class=\"ce\" style=\"height:4px\"></i>";
				continue;
			}
			var h = loss >= 100 || ms < 0 ? 24 : 6 + Math.round(18 * Math.min(ms, 350) / 350);
			html += "<i class=\"" + lossClass(loss) + "\" style=\"height:" + h + "px\" title=\"" +
				formatTime(r[0]).slice(5, 16) + "  延迟 " + (ms >= 0 ? ms + "ms" : "-") + "  丢包 " + fmtLoss(loss) + "\"></i>";
		}
		html += "</div><span class=\"p24-sum\">" + (sum[k][1] >= 0 ? sum[k][1] + "ms" : "-") + " / " +
			(sum[k][0] >= 0 ? fmtLoss(sum[k][0]) : "-") + "</span></div>";
	}
	html += "<div class=\"p24-axis\">";
	for (var a = 0; a <= 4; a++)
		html += "<span>" + fmtHM(d.start + a * 18 * d.step) + "</span>";
	html += "</div><div class=\"p24-legend\">丢包率:<b class=\"c0\"></b>0%<b class=\"c1\"></b>0~10%" +
		"<b class=\"c2\"></b>10~30%<b class=\"c3\"></b>&gt;30%<b class=\"cx\"></b>失联" +
		"<span style=\"float:right\">平均延迟 / 丢包率</span></div></div>";
	return html;
}

// 只在内容变化时才替换，避免每 3 秒重建导致闪烁、悬停弹窗消失
function setHtml(el, html) {
	if (el._html !== html) {
		el._html = html;
		el.innerHTML = html;
	}
}

// 位置显示为国旗（两位国家代码），图片加载失败时回退为文字
function flagImg(cc) {
	if (!/^[a-zA-Z]{2}$/.test(cc || ""))
		return cc || "–";
	cc = cc.toLowerCase();
	return "<img src=\"https://flagcdn.com/24x18/" + cc + ".png\" width=\"24\" height=\"18\" title=\"" + cc.toUpperCase() +
		"\" alt=\"" + cc + "\" style=\"vertical-align: middle; border-radius: 2px;\" onerror=\"this.outerHTML='" + cc + "'\">";
}

function uptime() {
	// 页面不可见时不刷新，节省流量
	if (document.hidden)
		return;
	loadPing24h();
	$.getJSON("json/stats.json", function(result) {
		$("#loading-notice").remove();
		// 主控更新后版本号变化，自动刷新页面加载新前端
		if (result.version) {
			if (!page_version)
				page_version = result.version;
			else if (page_version != result.version)
				result.reload = true;
		}
		if(result.reload)
			setTimeout(function() { location.reload() }, 1000);

		for (var i = 0, rlen=result.servers.length; i < rlen; i++) {
			var TableRow = $("#servers tr#r" + i);
			var ExpandRow = $("#servers #rt" + i);
			var hack; // fuck CSS for making me do this
			if(i%2) hack="odd"; else hack="even";
			if (!TableRow.length) {
				$("#servers").append(
					"<tr id=\"r" + i + "\" data-toggle=\"collapse\" data-target=\"#rt" + i + "\" class=\"accordion-toggle " + hack + "\">" +
						"<td id=\"online_status\"><div class=\"progress\"><div style=\"width: 100%;\" class=\"progress-bar progress-bar-warning\"><small>加载中</small></div></div></td>" +
						"<td id=\"month_traffic\"><div class=\"progress\"><div style=\"width: 100%;\" class=\"progress-bar progress-bar-warning\"><small>加载中</small></div></div></td>" +
						"<td id=\"name\">加载中</td>" +
						"<td id=\"type\">加载中</td>" +
						"<td id=\"location\">加载中</td>" +
						"<td id=\"uptime\">加载中</td>" +
						"<td id=\"load\">加载中</td>" +
						"<td id=\"network\">加载中</td>" +
						"<td id=\"traffic\">加载中</td>" +
						"<td id=\"cpu\"><div class=\"progress\"><div style=\"width: 100%;\" class=\"progress-bar progress-bar-warning\"><small>加载中</small></div></div></td>" +
						"<td id=\"memory\"><div class=\"progress\"><div style=\"width: 100%;\" class=\"progress-bar progress-bar-warning\"><small>加载中</small></div></div></td>" +
						"<td id=\"hdd\"><div class=\"progress\"><div style=\"width: 100%;\" class=\"progress-bar progress-bar-warning\"><small>加载中</small></div></div></td>" +
						"<td id=\"ping\"><div class=\"progress\"><div style=\"width: 100%;\" class=\"progress-bar progress-bar-warning\"><small>加载中</small></div></div></td>" +
					"</tr>" +
					"<tr class=\"expandRow " + hack + "\"><td colspan=\"16\"><div class=\"accordian-body collapse\" id=\"rt" + i + "\">" +
						"<div id=\"expand_boot\">加载中</div>" +
						"<div id=\"expand_mem\">加载中</div>" +
						"<div id=\"expand_swap\">加载中</div>" +
						"<div id=\"expand_hdd\">加载中</div>" +
						"<div id=\"expand_tupd\">加载中</div>" +
						"<div id=\"expand_ping\">加载中</div>" +
						"<div id=\"expand_custom\">加载中</div>" +
						"<div id=\"expand_cpu\">加载中</div>" +
					"</div></td></tr>"
				);
				TableRow = $("#servers tr#r" + i);
				ExpandRow = $("#servers #rt" + i);
				server_status[i] = true;
			}
			TableRow = TableRow[0];
			if(error) {
				TableRow.setAttribute("data-target", "#rt" + i);
				server_status[i] = true;
			}

			// online_status
			if (result.servers[i].online4 && !result.servers[i].online6) {
				TableRow.children["online_status"].children[0].children[0].className = "progress-bar progress-bar-success";
				TableRow.children["online_status"].children[0].children[0].innerHTML = "<small>IPv4</small>";
			} else if (result.servers[i].online4 && result.servers[i].online6) {
				TableRow.children["online_status"].children[0].children[0].className = "progress-bar progress-bar-success";
				TableRow.children["online_status"].children[0].children[0].innerHTML = "<small>双栈</small>";
			} else if (!result.servers[i].online4 && result.servers[i].online6) {
			    TableRow.children["online_status"].children[0].children[0].className = "progress-bar progress-bar-success";
				TableRow.children["online_status"].children[0].children[0].innerHTML = "<small>IPv6</small>";
			} else {
				TableRow.children["online_status"].children[0].children[0].className = "progress-bar progress-bar-danger";
				TableRow.children["online_status"].children[0].children[0].innerHTML = "<small>关闭</small>";
			}

			// Name
			TableRow.children["name"].innerHTML = result.servers[i].name;

			// Type
			TableRow.children["type"].innerHTML = result.servers[i].type;

			// Location
			TableRow.children["location"].innerHTML = flagImg(result.servers[i].location);
			if (!result.servers[i].online4 && !result.servers[i].online6) {
				if (server_status[i]) {
					TableRow.children["uptime"].innerHTML = "–";
					TableRow.children["uptime"].title = "";
					TableRow.children["load"].innerHTML = "–";
					TableRow.children["network"].innerHTML = "–";
					TableRow.children["traffic"].innerHTML = "–";
					TableRow.children["month_traffic"].children[0].children[0].className = "progress-bar progress-bar-warning";
					TableRow.children["month_traffic"].children[0].children[0].innerHTML = "<small>关闭</small>";
					TableRow.children["cpu"].children[0].children[0].className = "progress-bar progress-bar-danger";
					TableRow.children["cpu"].children[0].children[0].style.width = "100%";
					TableRow.children["cpu"].children[0].children[0].innerHTML = "<small>关闭</small>";
					TableRow.children["memory"].children[0].children[0].className = "progress-bar progress-bar-danger";
					TableRow.children["memory"].children[0].children[0].style.width = "100%";
					TableRow.children["memory"].children[0].children[0].innerHTML = "<small>关闭</small>";
					TableRow.children["hdd"].children[0].children[0].className = "progress-bar progress-bar-danger";
					TableRow.children["hdd"].children[0].children[0].style.width = "100%";
					TableRow.children["hdd"].children[0].children[0].innerHTML = "<small>关闭</small>";
					TableRow.children["ping"].children[0].className = "progress";
					TableRow.children["ping"].children[0].children[0].className = "progress-bar progress-bar-danger";
					TableRow.children["ping"].children[0].children[0].style.width = "100%";
					TableRow.children["ping"].children[0].children[0].innerHTML = "<small>关闭</small>";
					TableRow.children["ping"].children[0].children[0]._p24 = false;
					if(ExpandRow.hasClass("in")) {
						ExpandRow.collapse("hide");
					}
					TableRow.setAttribute("data-target", "");
					server_status[i] = false;
				}
			} else {
				if (!server_status[i]) {
					TableRow.setAttribute("data-target", "#rt" + i);
					server_status[i] = true;
				}

				// month traffic
				var monthtraffic = "";
				var trafficdiff_in = result.servers[i].network_in - result.servers[i].last_network_in;
				var trafficdiff_out = result.servers[i].network_out - result.servers[i].last_network_out;
				if(trafficdiff_in < 1024*1024*1024*1024)
					monthtraffic += (trafficdiff_in/1024/1024/1024).toFixed(1) + "G";
				else
					monthtraffic += (trafficdiff_in/1024/1024/1024/1024).toFixed(1) + "T";
				monthtraffic += " | "
				if(trafficdiff_out < 1024*1024*1024*1024)
					monthtraffic += (trafficdiff_out/1024/1024/1024).toFixed(1) + "G";
				else
					monthtraffic += (trafficdiff_out/1024/1024/1024/1024).toFixed(1) + "T";
				TableRow.children["month_traffic"].children[0].children[0].className = "progress-bar progress-bar-success";
				TableRow.children["month_traffic"].children[0].children[0].innerHTML = "<small>"+monthtraffic+"</small>";

				// Uptime
				TableRow.children["uptime"].innerHTML = result.servers[i].uptime;
				// 启动时间：鼠标悬停在线时长可查看，展开详情中也显示
				var boot = formatTime(result.servers[i].boot_time);
				TableRow.children["uptime"].title = "启动于 " + boot;
				ExpandRow[0].children["expand_boot"].innerHTML = "启动时间: " + boot;

				// Load: default load_1, you can change show: load_1, load_5, load_15
				if(result.servers[i].load == -1) {
				    TableRow.children["load"].innerHTML = "–";
				} else {
				    TableRow.children["load"].innerHTML = result.servers[i].load_1.toFixed(2);
				}

				// Network
				var netstr = "";
				if(result.servers[i].network_rx < 1024*1024)
					netstr += (result.servers[i].network_rx/1024).toFixed(1) + "K";
				else
					netstr += (result.servers[i].network_rx/1024/1024).toFixed(1) + "M";
				netstr += " | "
				if(result.servers[i].network_tx < 1024*1024)
					netstr += (result.servers[i].network_tx/1024).toFixed(1) + "K";
				else
					netstr += (result.servers[i].network_tx/1024/1024).toFixed(1) + "M";
				TableRow.children["network"].innerHTML = netstr;

				//Traffic
				var trafficstr = "";
				if(result.servers[i].network_in < 1024*1024*1024*1024)
					trafficstr += (result.servers[i].network_in/1024/1024/1024).toFixed(1) + "G";
                else
                    trafficstr += (result.servers[i].network_in/1024/1024/1024/1024).toFixed(1) + "T";
				trafficstr += " | "
				if(result.servers[i].network_out < 1024*1024*1024*1024)
				    trafficstr += (result.servers[i].network_out/1024/1024/1024).toFixed(1) + "G";
				else
					trafficstr += (result.servers[i].network_out/1024/1024/1024/1024).toFixed(1) + "T";
				TableRow.children["traffic"].innerHTML = trafficstr;

				// CPU
				if (result.servers[i].cpu >= 90)
					TableRow.children["cpu"].children[0].children[0].className = "progress-bar progress-bar-danger";
				else if (result.servers[i].cpu >= 80)
					TableRow.children["cpu"].children[0].children[0].className = "progress-bar progress-bar-warning";
				else
					TableRow.children["cpu"].children[0].children[0].className = "progress-bar progress-bar-success";
				TableRow.children["cpu"].children[0].children[0].style.width = result.servers[i].cpu + "%";
				TableRow.children["cpu"].children[0].children[0].innerHTML = result.servers[i].cpu + "%";

				// Memory
				var Mem = ((result.servers[i].memory_used/result.servers[i].memory_total)*100.0).toFixed(0);
				if (Mem >= 90)
					TableRow.children["memory"].children[0].children[0].className = "progress-bar progress-bar-danger";
				else if (Mem >= 80)
					TableRow.children["memory"].children[0].children[0].className = "progress-bar progress-bar-warning";
				else
					TableRow.children["memory"].children[0].children[0].className = "progress-bar progress-bar-success";
				TableRow.children["memory"].children[0].children[0].style.width = Mem + "%";
				TableRow.children["memory"].children[0].children[0].innerHTML = Mem + "%";
				// 处理器型号
				ExpandRow[0].children["expand_cpu"].innerHTML = "处理器: " + (result.servers[i].cpu_info || "未知");
				ExpandRow[0].children["expand_mem"].innerHTML = "内存: " + bytesToSize(result.servers[i].memory_used*1024, 2) + " / " + bytesToSize(result.servers[i].memory_total*1024, 2);
				// Swap
				ExpandRow[0].children["expand_swap"].innerHTML = "交换分区: " + bytesToSize(result.servers[i].swap_used*1024, 2) + " / " + bytesToSize(result.servers[i].swap_total*1024, 2);

				// HDD
				var HDD = ((result.servers[i].hdd_used/result.servers[i].hdd_total)*100.0).toFixed(0);
				if (HDD >= 90)
					TableRow.children["hdd"].children[0].children[0].className = "progress-bar progress-bar-danger";
				else if (HDD >= 80)
					TableRow.children["hdd"].children[0].children[0].className = "progress-bar progress-bar-warning";
				else
					TableRow.children["hdd"].children[0].children[0].className = "progress-bar progress-bar-success";
				TableRow.children["hdd"].children[0].children[0].style.width = HDD + "%";
				TableRow.children["hdd"].children[0].children[0].innerHTML = HDD + "%";
				// IO Speed for HDD.
				// IO， 过小的B字节单位没有意义
				var io = "";
				if(result.servers[i].io_read < 1024*1024)
					io += parseInt(result.servers[i].io_read/1024) + "K";
				else
					io += parseInt(result.servers[i].io_read/1024/1024) + "M";
				io += " / "
				if(result.servers[i].io_write < 1024*1024)
					io += parseInt(result.servers[i].io_write/1024) + "K";
				else
					io += parseInt(result.servers[i].io_write/1024/1024) + "M";
				// Expand for HDD.
				ExpandRow[0].children["expand_hdd"].innerHTML = "硬盘|读写: " + bytesToSize(result.servers[i].hdd_used*1024*1024, 2) + " / " + bytesToSize(result.servers[i].hdd_total*1024*1024, 2) + " | " + io;

                // delay time

				// tcp, udp, process, thread count
				ExpandRow[0].children["expand_tupd"].innerHTML = "TCP/UDP/进/线: " + result.servers[i].tcp_count + " / " + result.servers[i].udp_count + " / " + result.servers[i].process_count+ " / " + result.servers[i].thread_count;
                // ping：三网实时丢包率（客户端最近一个探测窗口），详情中同时显示延迟
                var PING_10010 = result.servers[i].ping_10010.toFixed(0);
                var PING_189 = result.servers[i].ping_189.toFixed(0);
                var PING_10086 = result.servers[i].ping_10086.toFixed(0);
                var ms = function(t) { return t > 0 ? t + "ms" : "-"; };
				ExpandRow[0].children["expand_ping"].innerHTML = "实时 联通/电信/移动: " +
					ms(result.servers[i].time_10010) + " (" + PING_10010 + "%) / " +
					ms(result.servers[i].time_189) + " (" + PING_189 + "%) / " +
					ms(result.servers[i].time_10086) + " (" + PING_10086 + "%)";
                // 三网实时丢包率（原版样式），任一线路 >= 20% 时变色；悬停弹出 24 小时丢包图
                var bar = TableRow.children["ping"].children[0].children[0];
                TableRow.children["ping"].children[0].className = "progress";
                if (PING_10010 >= 20 || PING_189 >= 20 || PING_10086 >= 20)
                    bar.className = "progress-bar progress-bar-warning";
                else
                    bar.className = "progress-bar progress-bar-success";
                bar.style.width = "100%";
                // 文字与弹窗分开更新，数值变化时不会重建弹窗
                if (!bar._p24) {
                    bar.innerHTML = "<span></span><div class=\"p24-pop\"></div>";
                    bar._p24 = true;
                }
                bar.children[0].textContent = PING_10010 + "%💻" + PING_189 + "%💻" + PING_10086 + "%";
                var rows = p24.data && p24.data.nodes[result.servers[i].id], chart = "";
                var sum = rows ? p24Summary(rows) : [];
                if (sum.some(function(x) { return x[0] >= 0; }))
                    chart = p24Chart(rows, sum);
                setHtml(bar.children[1], chart);

				// Custom
				if (result.servers[i].custom) {
					ExpandRow[0].children["expand_custom"].innerHTML = result.servers[i].custom
				} else {
					ExpandRow[0].children["expand_custom"].innerHTML = ""
				}
			}
		};

		d = new Date(result.updated*1000);
		error = 0;
	}).fail(function(update_error) {
		if (!error) {
			$("#servers > tr.accordion-toggle").each(function(i) {
				var TableRow = $("#servers tr#r" + i)[0];
				var ExpandRow = $("#servers #rt" + i);
				TableRow.children["online_status"].children[0].children[0].className = "progress-bar progress-bar-error";
				TableRow.children["online_status"].children[0].children[0].innerHTML = "<small>错误</small>";
				TableRow.children["month_traffic"].children[0].children[0].className = "progress-bar progress-bar-error";
				TableRow.children["month_traffic"].children[0].children[0].innerHTML = "<small>错误</small>";
				TableRow.children["uptime"].children[0].children[0].className = "progress-bar progress-bar-error";
				TableRow.children["uptime"].children[0].children[0].innerHTML = "<small>错误</small>";
				TableRow.children["load"].children[0].children[0].className = "progress-bar progress-bar-error";
				TableRow.children["load"].children[0].children[0].innerHTML = "<small>错误</small>";
				TableRow.children["network"].children[0].children[0].className = "progress-bar progress-bar-error";
				TableRow.children["network"].children[0].children[0].innerHTML = "<small>错误</small>";
				TableRow.children["traffic"].children[0].children[0].className = "progress-bar progress-bar-error";
				TableRow.children["traffic"].children[0].children[0].innerHTML = "<small>错误</small>";
				TableRow.children["cpu"].children[0].children[0].className = "progress-bar progress-bar-error";
				TableRow.children["cpu"].children[0].children[0].style.width = "100%";
				TableRow.children["cpu"].children[0].children[0].innerHTML = "<small>错误</small>";
				TableRow.children["memory"].children[0].children[0].className = "progress-bar progress-bar-error";
				TableRow.children["memory"].children[0].children[0].style.width = "100%";
				TableRow.children["memory"].children[0].children[0].innerHTML = "<small>错误</small>";
				TableRow.children["hdd"].children[0].children[0].className = "progress-bar progress-bar-error";
				TableRow.children["hdd"].children[0].children[0].style.width = "100%";
				TableRow.children["hdd"].children[0].children[0].innerHTML = "<small>错误</small>";
				TableRow.children["ping"].children[0].children[0].className = "progress-bar progress-bar-error";
				TableRow.children["ping"].children[0].children[0].style.width = "100%";
				TableRow.children["ping"].children[0].children[0].innerHTML = "<small>错误</small>";
				TableRow.children["ping"].children[0].children[0]._p24 = false;
				if(ExpandRow.hasClass("in")) {
					ExpandRow.collapse("hide");
				}
				TableRow.setAttribute("data-target", "");
				server_status[i] = false;
			});
		}
		error = 1;
		$("#updated").html("更新错误.");
	});
}

function updateTime() {
	if (!error)
		$("#updated").html("最后更新: " + timeSince(d));
}

uptime();
updateTime();
setInterval(uptime, 3000);
setInterval(updateTime, 2000);


// styleswitcher.js
function setActiveStyleSheet(title, cookie=false) {
        var i, a, main;
        for(i=0; (a = document.getElementsByTagName("link")[i]); i++) {
                if(a.getAttribute("rel").indexOf("style") != -1 && a.getAttribute("title")) {
                        a.disabled = true;
                        if(a.getAttribute("title") == title) a.disabled = false;
                }
        }
        if (true==cookie) {
                createCookie("style", title, 365);
        }
}

function getActiveStyleSheet() {
	var i, a;
	for(i=0; (a = document.getElementsByTagName("link")[i]); i++) {
		if(a.getAttribute("rel").indexOf("style") != -1 && a.getAttribute("title") && !a.disabled)
			return a.getAttribute("title");
	}
	return null;
}

function createCookie(name,value,days) {
	if (days) {
		var date = new Date();
		date.setTime(date.getTime()+(days*24*60*60*1000));
		var expires = "; expires="+date.toGMTString();
	}
	else expires = "";
	document.cookie = name+"="+value+expires+"; path=/";
}

function readCookie(name) {
	var nameEQ = name + "=";
	var ca = document.cookie.split(';');
	for(var i=0;i < ca.length;i++) {
		var c = ca[i];
		while (c.charAt(0)==' ')
			c = c.substring(1,c.length);
		if (c.indexOf(nameEQ) == 0)
			return c.substring(nameEQ.length,c.length);
	}
	return null;
}

window.onload = function(e) {
        var cookie = readCookie("style");
        if (cookie && cookie != 'null' ) {
                setActiveStyleSheet(cookie);
        } else {
                function handleChange (mediaQueryListEvent) {
                        if (mediaQueryListEvent.matches) {
                                setActiveStyleSheet('dark');
                        } else {
                                setActiveStyleSheet('light');
                        }
                }
                const mediaQueryListDark = window.matchMedia('(prefers-color-scheme: dark)');
                setActiveStyleSheet(mediaQueryListDark.matches ? 'dark' : 'light');
                mediaQueryListDark.addEventListener("change",handleChange);
        }
}
