// OpenClash Multiport v1.0.1
(function () {
  'use strict';
  function init() {
    var root = document.getElementById('oc-multiport');
    if (!root || root.getAttribute('data-oc-mp-initialized') === 'true') return;
    root.setAttribute('data-oc-mp-initialized', 'true');
    var entries = [], editing = null, revision = 0, ready = false, busy = false;
    var latencies = Object.create(null), probeQueue = [], activeProbes = 0, probeEpoch = 0;
    var initialProbes = [], initialProbeDone = Object.create(null);
    var nodeList = [], nodeConfig = '', nodeEpoch = 0, nodeLoading = false;
    var nodeJobs = [], nodeActive = 0, nodeDelays = Object.create(null), nodeIPs = Object.create(null);
    var apiBase = root.getAttribute('data-api-base'), apiToken = root.getAttribute('data-api-token');
    var $ = function (id) { return document.getElementById('oc-mp-' + id); };
    function setupTooltips() {
      var tip = document.createElement('div'), owner = null;
      tip.id = 'oc-mp-tooltip'; tip.className = 'oc-mp-tooltip';
      tip.setAttribute('role', 'tooltip'); tip.setAttribute('popover', 'manual'); tip.hidden = true;
      function convert(el) {
        if (!el || !el.hasAttribute('title')) return;
        el.setAttribute('data-oc-mp-tooltip', el.getAttribute('title'));
        el.removeAttribute('title');
      }
      function scan(el) {
        if (!el || !el.querySelectorAll) return;
        convert(el); el.querySelectorAll('[title]').forEach(convert);
      }
      function hide() {
        if (owner) {
          var ids = (owner.getAttribute('aria-describedby') || '').split(/\s+/).filter(function (id) { return id && id !== tip.id; });
          if (ids.length) owner.setAttribute('aria-describedby', ids.join(' '));
          else owner.removeAttribute('aria-describedby');
        }
        owner = null;
        if (typeof tip.hidePopover === 'function') { try { tip.hidePopover(); } catch (e) {} }
        tip.hidden = true;
      }
      function show(el) {
        convert(el);
        var text = el.getAttribute('data-oc-mp-tooltip');
        if (!text || !el.isConnected) { hide(); return; }
        hide(); owner = el;
        // Place the hint in the same modal, and use the top layer to escape table clipping.
        var dialog = el.closest('dialog[open]'), parent = dialog || document.body;
        if (tip.parentNode !== parent) parent.appendChild(tip);
        if (window.getComputedStyle) {
          var theme = window.getComputedStyle(root);
          ['--bg-white', '--border-light', '--text-primary', '--text-secondary'].forEach(function (key) {
            tip.style.setProperty(key, theme.getPropertyValue(key));
          });
        }
        tip.textContent = '';
        var lines = text.split('\n');
        lines.forEach(function (line, index) {
          var part = document.createElement('div'); part.textContent = line;
          part.className = 'oc-mp-tooltip-line' + (lines.length > 1 && index === lines.length - 1 && /^点击/.test(line) ? ' oc-mp-tooltip-hint' : '');
          tip.appendChild(part);
        });
        var ids = (el.getAttribute('aria-describedby') || '').split(/\s+/).filter(Boolean);
        ids.push(tip.id); el.setAttribute('aria-describedby', ids.join(' '));
        tip.hidden = false;
        if (typeof tip.showPopover === 'function') { try { tip.showPopover(); } catch (e) {} }
        var rect = el.getBoundingClientRect(), box = tip.getBoundingClientRect();
        var width = document.documentElement.clientWidth || window.innerWidth;
        var height = document.documentElement.clientHeight || window.innerHeight;
        var left = Math.max(8, Math.min(rect.left + (rect.width - box.width) / 2, width - box.width - 8));
        var top = rect.top - box.height - 8;
        if (top < 8) top = rect.bottom + 8;
        top = Math.max(8, Math.min(top, height - box.height - 8));
        tip.style.left = left + 'px'; tip.style.top = top + 'px';
      }
      function target(node) {
        if (!node || !node.closest) return null;
        var el = node.closest('[data-oc-mp-tooltip], [title]');
        return el && root.contains(el) ? el : null;
      }
      root.addEventListener('pointerover', function (event) {
        var el = target(event.target);
        if (el && el !== owner && event.pointerType !== 'touch') show(el);
      });
      root.addEventListener('pointerout', function (event) {
        if (owner && !owner.contains(event.relatedTarget)) hide();
      });
      root.addEventListener('focusin', function (event) { var el = target(event.target); if (el) show(el); });
      root.addEventListener('focusout', hide);
      root.addEventListener('click', hide);
      root.addEventListener('close', hide, true);
      document.addEventListener('keydown', function (event) { if (event.key === 'Escape') hide(); }, true);
      document.addEventListener('scroll', hide, true);
      window.addEventListener('resize', hide);
      scan(root);
      // Also catch titles updated by the shared clipboard helper and newly rendered rows.
      var observer = new MutationObserver(function (records) {
        var updated = false;
        (records || []).forEach(function (record) {
          if (record.type === 'attributes') {
            if (record.target === owner && record.target.hasAttribute('title')) updated = true;
            convert(record.target);
          }
          else record.addedNodes.forEach(scan);
        });
        if (owner && !owner.isConnected) hide();
        else if (owner && updated) show(owner);
      });
      observer.observe(root, {subtree: true, childList: true, attributes: true, attributeFilter: ['title']});
    }
    setupTooltips();
    function message(s) { var el = $('message'); el.textContent = s; el.hidden = false; }
    function valid(e) { return e && typeof e.id === 'string' && typeof e.label === 'string' && typeof e.host === 'string' && typeof e.node === 'string' && Number.isInteger(e.port) && e.port >= 1024 && e.port <= 65535 && typeof e.enabled === 'boolean'; }
    async function request(action, payload) {
      var options = { method: payload ? 'POST' : 'GET', credentials: 'same-origin', cache: 'no-store' };
      if (payload) {
        options.headers = { 'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8' };
        options.body = 'token=' + encodeURIComponent(apiToken) + '&payload=' + encodeURIComponent(JSON.stringify(payload));
      }
      var response;
      try { response = await fetch(apiBase + '/' + action, options); }
      catch (error) { throw new Error('连接中断，请刷新页面核对路由器配置后重试。'); }
      var result;
      try { result = await response.json(); }
      catch (error) {
        if (response.redirected || response.status === 401 || response.status === 403) {
          throw new Error('LuCI 登录已失效或请求被拒绝，请重新登录后刷新。');
        }
        if (response.status === 404) throw new Error('代理配置接口不存在（HTTP 404），请检查后端文件位置并重启 rpcd。');
        throw new Error('代理配置接口未返回有效 JSON（HTTP ' + response.status + '），请打开 state 接口查看错误。');
      }
      if (!response.ok || !result.ok) {
        var failure = new Error(result.error || '应用失败，请检查 OpenClash 运行状态。');
        failure.conflict = result.conflict === true;
        throw failure;
      }
      if (action === 'nodes') {
        if (typeof result.config !== 'string' || !Array.isArray(result.nodes) || !result.nodes.every(function (n) {
          return n && typeof n.name === 'string' && typeof n.type === 'string' && typeof n.available === 'boolean' &&
            (n.server === null || typeof n.server === 'string') && (n.ip === null || typeof n.ip === 'string') &&
            (n.delay === null || (Number.isInteger(n.delay) && n.delay > 0 && n.delay <= 65535));
        })) throw new Error('节点列表格式错误，请更新配套后端。');
        return result;
      }
      if (action === 'node_delay' || action === 'node_ip') {
        if (result.name !== payload.name || (action === 'node_delay' ?
            !(result.delay === null || (Number.isInteger(result.delay) && result.delay > 0 && result.delay <= 65535)) :
            !(result.ip === null || typeof result.ip === 'string'))) throw new Error('节点详情格式错误，请刷新列表。');
        return result;
      }
      if (action === 'delay') {
        if (result.id !== payload.id || result.revision !== payload.revision ||
            !(result.delay === null || (Number.isInteger(result.delay) && result.delay > 0 && result.delay <= 65535)) ||
            !(result.node === null || typeof result.node === 'string')) {
          throw new Error('后端返回的延迟数据格式错误，请更新配套后端。');
        }
        return result;
      }
      // Compatibility with old LuCI controllers that re-encoded empty [] as {}.
      if (result.entries && !Array.isArray(result.entries) && typeof result.entries === 'object' && Object.keys(result.entries).length === 0) {
        result.entries = [];
      }
      if (!Array.isArray(result.entries) || !Number.isInteger(result.revision) || !result.entries.every(valid)) {
        throw new Error('后端返回的代理配置格式错误，请刷新页面。');
      }
      return result;
    }
    function accept(result) { entries = result.entries; revision = result.revision; ready = true; $('message').hidden = true; }
    function hasPendingProbes() { return Object.keys(latencies).some(function (id) { return latencies[id].pending; }); }
    function controls() {
      var refreshing = hasPendingProbes();
      $('add').disabled = !ready || busy;
      $('refresh').disabled = !ready || busy || refreshing;
      $('refresh').classList.toggle('oc-mp-refreshing', refreshing);
      $('refresh').setAttribute('aria-busy', String(refreshing));
      $('refresh-label').textContent = refreshing ? '刷新中…' : '刷新延迟';
      ['confirm', 'cancel', 'cancel-x', 'choose-node'].forEach(function (id) { $(id).disabled = busy; });
      $('confirm').textContent = busy ? '正在应用…' : '保存并应用';
    }
    async function persist(next) {
      if (!ready || busy) return false;
      var previousEntries = entries, changedProbes = [];
      // An edit ends startup detection, including a default probe waiting for
      // OpenClash status. Only this apply's changed rows may start afterwards.
      initialProbes = [];
      // Reload invalidates in-flight requests, but completed measurements for
      // unchanged entries remain useful. Restore the last value behind a spinner.
      probeEpoch++; probeQueue = [];
      Object.keys(latencies).forEach(function (id) {
        var value = latencies[id];
        if (value.pending) latencies[id] = value.previous || {pending: false, delay: null,
          note: '检测已取消，点击重新检测', address: value.address};
      });
      busy = true; $('message').hidden = true; controls(); render();
      try {
        accept(await request('apply', { revision: revision, entries: next }));
        Object.keys(latencies).forEach(function (id) {
          if (id !== 'default' && !entries.some(function (e) { return e.id === id; })) delete latencies[id];
        });
        entries.forEach(function (e) {
          var old = previousEntries.find(function (p) { return p.id === e.id; });
          var changed = !old || ['host', 'port', 'node', 'username', 'password', 'enabled'].some(function (key) { return old[key] !== e[key]; });
          if (!changed) return;
          delete latencies[e.id];
          if (e.enabled && e.applied !== false) changedProbes.push(e.id);
        });
        return true;
      } finally {
        busy = false; controls(); render();
        changedProbes.forEach(function (id) { refreshDelays(id); });
        drainProbes();
      }
    }
    function button(text, action, danger) {
      var b = document.createElement('button'); b.type = 'button';
      b.className = 'icon-btn oc-mp-icon-button' + (danger ? ' oc-mp-danger' : '');
      b.title = text; b.setAttribute('aria-label', text);
      var paths = {
        '复制认证信息': 'M7 10V7a5 5 0 0 1 10 0v3 M5 10h14v11H5z M12 14v3',
        '复制': 'M9 9h11v11H9z M15 5V3H3v12h2',
        '编辑': 'm15 5 4 4 M4 20l4-1L20 7a2.8 2.8 0 0 0-4-4L4 15l-1 6z',
        '删除': 'M4 7h16 M9 7V4h6v3 M6 7l1 13h10l1-13 M10 11v5 M14 11v5'
      };
      var ns = 'http://www.w3.org/2000/svg', svg = document.createElementNS(ns, 'svg');
      svg.setAttribute('viewBox', '0 0 24 24'); svg.setAttribute('width', '14'); svg.setAttribute('height', '14');
      svg.setAttribute('fill', 'none'); svg.setAttribute('stroke', 'currentColor'); svg.setAttribute('stroke-width', '1.7');
      svg.setAttribute('stroke-linecap', 'round'); svg.setAttribute('stroke-linejoin', 'round'); svg.setAttribute('aria-hidden', 'true');
      var path = document.createElementNS(ns, 'path'); path.setAttribute('d', paths[text] || paths['编辑']);
      svg.appendChild(path); b.appendChild(svg); b.addEventListener('click', action); return b;
    }
    function defaultInfo() {
      var el = document.getElementById('_mix_proxy');
      var text = el ? el.textContent.trim() : '';
      var match = text.match(/^(.+):(\d+)$/);
      var status = typeof StateManager !== 'undefined' ? StateManager.current_status : null;
      var loading = !match && (!text || /Collecting|收集/.test(text));
      return { address: match ? text : (loading ? '读取中…' : '暂不可用'),
        port: match ? Number(match[2]) : null,
        ready: !!match, running: !!match && (!status || !!status.clash), loading: loading };
    }
    function proxyAuth() {
      var info = typeof StateManager !== 'undefined' ? StateManager.cached_proxy_info : null;
      return info && info.auth_user && info.auth_pass ? info.auth_user + ':' + info.auth_pass : '';
    }
    function stateSwitch(entry) {
      var label = document.createElement('label'); label.className = 'oc-mp-switch';
      var input = document.createElement('input'); input.type = 'checkbox'; input.setAttribute('role', 'switch');
      input.checked = entry ? entry.enabled : true; input.disabled = !entry || busy || !ready;
      input.setAttribute('aria-checked', String(input.checked));
      input.setAttribute('aria-label', entry ? '启用代理 ' + entry.host + ':' + entry.port : '默认混合代理始终开启');
      label.title = entry ? (entry.applied === false ? '配置与内核状态不一致，请检查 OpenClash；切换后会重新应用' : '启用 / 停用，自动应用到路由器') : '默认混合代理不允许关闭';
      var track = document.createElement('span'); track.className = 'oc-mp-switch-track'; track.setAttribute('aria-hidden', 'true');
      if (entry) input.addEventListener('change', async function () {
        var enabled = input.checked;
        input.checked = entry.enabled;
        try { await persist(entries.map(function (e) { return e.id === entry.id ? Object.assign({}, e, {enabled: enabled}) : e; })); }
        catch (error) { message(error.message); }
      });
      label.appendChild(input); label.appendChild(track); return label;
    }
    function defaultRow(body) {
      var info = defaultInfo(), tr = document.createElement('tr');
      tr.className = 'oc-mp-default-row';
      function cell(text) { var td = document.createElement('td'); if (text) td.textContent = text; tr.appendChild(td); return td; }
      var label = cell(), address = document.createElement('span'); address.className = 'oc-mp-address'; address.textContent = info.address; label.appendChild(address);
      cell('当前策略出口'); latencyCell(cell(), 'default');
      cell().appendChild(stateSwitch(null));
      var actions = document.createElement('div'); actions.className = 'oc-mp-row-actions';
      var copyButton = button('复制', function (event) { copy(info.address, event.currentTarget); }); copyButton.disabled = !info.ready; actions.appendChild(copyButton);
      var authButton = button('复制认证信息', function (event) {
        var auth = proxyAuth();
        if (auth) copy(auth, event.currentTarget);
      });
      authButton.disabled = !proxyAuth();
      if (authButton.disabled) authButton.title = '未设置代理认证信息';
      actions.appendChild(authButton);
      var editButton = button('编辑', function () {});
      editButton.disabled = true; editButton.title = '默认混合代理不可编辑'; actions.appendChild(editButton);
      var deleteButton = button('删除', function () {});
      deleteButton.disabled = true; deleteButton.title = '默认混合代理不可删除'; actions.appendChild(deleteButton);
      cell().appendChild(actions); body.appendChild(tr);
    }
    function render() {
      var body = $('rows'); body.textContent = '';
      $('count').textContent = (entries.length + 1) + ' 个端口';
      defaultRow(body);
      entries.forEach(function (e) {
        var tr = document.createElement('tr');
        function cell(s) { var td = document.createElement('td'); if (s !== undefined) td.textContent = s; tr.appendChild(td); return td; }
        var label = cell(), addr = document.createElement('span'); addr.className = 'oc-mp-address'; addr.textContent = e.host + ':' + e.port; label.appendChild(addr);
        cell(e.node); latencyCell(cell(), e.id); cell().appendChild(stateSwitch(e));
        var actions = document.createElement('div'); actions.className = 'oc-mp-row-actions';
        actions.appendChild(button('复制', function (event) { copy(addr.textContent, event.currentTarget); }));
        var authButton = button('复制认证信息', function (event) {
          if (e.username && e.password) copy(e.username + ':' + e.password, event.currentTarget);
        });
        authButton.disabled = !(e.username && e.password);
        authButton.title = authButton.disabled ? '入口尚未配置认证信息' : '复制认证信息'; actions.appendChild(authButton);
        var editButton = button('编辑', function () { open(e.id); }); editButton.disabled = busy; actions.appendChild(editButton);
        var deleteButton = button('删除', async function () {
          if (busy || !window.confirm('删除入口 ' + e.host + ':' + e.port + ' 并应用到路由器？')) return;
          try { await persist(entries.filter(function (x) { return x.id !== e.id; })); }
          catch (error) { message(error.message); }
        }, true); deleteButton.disabled = busy; actions.appendChild(deleteButton);
        cell().appendChild(actions); body.appendChild(tr);
      });
    }
    function probeTarget(id) {
      if (id === 'default') {
        var info = defaultInfo();
        return {id: id, host: info.ready ? info.address.slice(0, info.address.lastIndexOf(':')) : '',
          address: info.address, enabled: info.running, note: '默认混合代理暂不可用'};
      }
      var e = entries.find(function (item) { return item.id === id; });
      return e ? {id: id, host: e.host, enabled: e.enabled && e.applied !== false,
        note: e.enabled ? '入口尚未应用到内核' : '代理已停用'} : null;
    }
    function latencyCell(cell, id) {
      var value = latencies[id], target = probeTarget(id);
      if (id === 'default' && value && value.address !== target.address) value = null;
      var pending = !!(value && value.pending), tag = document.createElement('button');
      cell.className = 'oc-mp-latency'; cell.setAttribute('aria-busy', String(pending));
      tag.type = 'button'; tag.className = 'oc-mp-delay-tag';
      tag.disabled = !ready || busy || pending || !target || !target.enabled;
      if (pending) {
        tag.classList.add('oc-mp-delay-loading');
        var spinner = document.createElement('span'); spinner.className = 'oc-mp-delay-spinner';
        spinner.setAttribute('aria-hidden', 'true'); tag.appendChild(spinner);
        tag.setAttribute('aria-label', value.running ? '正在检测此代理…' : '等待检测此代理…');
      } else if (value && value.delay !== null) {
        tag.classList.add('oc-mp-delay-' + (value.delay <= 200 ? 'low' : value.delay <= 500 ? 'medium' : 'high'));
        tag.textContent = value.delay + ' ';
        var unit = document.createElement('span'); unit.className = 'oc-mp-delay-unit'; unit.textContent = 'ms'; tag.appendChild(unit);
        tag.setAttribute('aria-label', '节点延迟：' + value.delay + ' ms；点击刷新');
      } else {
        tag.classList.add('oc-mp-delay-empty'); tag.textContent = '-';
        tag.title = value ? (value.note || '本次检测未获得有效延迟，请重试') : (target && !target.enabled ? target.note : '尚未检测节点延迟');
        tag.setAttribute('aria-label', tag.title);
      }
      if (tag.hasAttribute('title')) cell.title = tag.title;
      tag.addEventListener('click', function () { refreshDelays(id); });
      cell.appendChild(tag);
    }
    function refreshDelays(id) {
      if (!ready || busy || (!id && hasPendingProbes())) return;
      $('message').hidden = true;
      var ids = id ? [id] : ['default'].concat(entries.map(function (e) { return e.id; }));
      ids.forEach(function (key) {
        var target = probeTarget(key), previous = latencies[key];
        if (!target || (previous && previous.pending)) return;
        var state = {pending: target.enabled, delay: null, node: null,
          note: target.enabled ? '' : target.note,
          address: target.address, previous: target.enabled ? previous : undefined};
        latencies[key] = state;
        if (target.enabled) {
          initialProbeDone[key] = true;
          probeQueue.push({id: key, host: target.host, address: target.address,
            revision: revision, epoch: probeEpoch, state: state});
        }
      });
      controls(); render(); drainProbes();
    }
    function currentProbe(job) {
      return job.epoch === probeEpoch && job.revision === revision && latencies[job.id] === job.state;
    }
    function scheduleAutomaticProbes() {
      // Initial page load only. Later edits enqueue only the affected entries.
      initialProbeDone = Object.create(null);
      initialProbes = ['default'].concat(entries.filter(function (e) { return e.enabled && e.applied !== false; }).map(function (e) { return e.id; }));
      runInitialProbes();
    }
    function runInitialProbes() {
      if (!ready || busy || !initialProbes.length) return;
      var pending = initialProbes; initialProbes = [];
      pending.forEach(function (id) {
        var target = probeTarget(id);
        // The original status script may publish the mixed address later.
        if (id === 'default' && (!target || !target.enabled)) { initialProbes.push(id); return; }
        // A manual refresh already counts; never duplicate a request or retry
        // a failed automatic probe on subsequent status updates.
        if (target && target.enabled && !initialProbeDone[id]) refreshDelays(id);
      });
    }
    function drainProbes() {
      // One scheduler for batch and single-row refreshes; never duplicate a row.
      while (!busy && activeProbes < 5 && probeQueue.length) {
        var job = probeQueue.shift();
        if (!currentProbe(job)) continue;
        activeProbes++; job.state.running = true;
        runProbe(job);
      }
    }
    async function runProbe(job) {
      try {
        var result = await request('delay', {id: job.id, host: job.host, revision: job.revision});
        if (!currentProbe(job)) return;
        if (job.id === 'default' && defaultInfo().address !== job.address) { delete latencies[job.id]; return; }
        job.state.delay = result.delay; job.state.node = result.node;
        job.state.note = result.note || '';
      } catch (error) {
        if (currentProbe(job)) {
          job.state.delay = null; job.state.node = null; job.state.note = error.message;
        }
      } finally {
        if (currentProbe(job)) { job.state.pending = false; delete job.state.previous; }
        activeProbes--; drainProbes(); controls(); render();
      }
    }
    function pickerMessage(text) {
      $('node-message').textContent = text; $('node-message').hidden = !text;
    }
    function pickerControls() {
      var pending = Object.keys(nodeDelays).some(function (name) { return nodeDelays[name].pending; });
      $('node-reload').disabled = nodeLoading;
      $('node-refresh').disabled = nodeLoading || pending || !nodeList.some(function (n) { return n.available; });
      $('node-refresh').textContent = pending ? '刷新中…' : '刷新延迟';
      $('node-grid').setAttribute('aria-busy', String(nodeLoading));
    }
    function visibleNodes() {
      var query = $('node-search').value.trim().toLowerCase();
      return nodeList.filter(function (n) {
        var ip = nodeIPs[n.name];
        return !query || [n.name, n.type, n.server || '', ip && ip.ip || n.ip || ''].join(' ').toLowerCase().includes(query);
      });
    }
    function renderNodes() {
      var grid = $('node-grid'), scrollTop = grid.scrollTop, active = document.activeElement;
      var focusedCard = active && grid.contains(active) ? active.closest('.oc-mp-node-card') : null;
      var focusedName = focusedCard ? focusedCard.getAttribute('data-node-name') : null;
      var focusedDelay = focusedCard && active.classList.contains('oc-mp-delay-tag');
      grid.textContent = '';
      var shown = visibleNodes(), selected = $('node').value;
      $('node-count').textContent = (shown.length === nodeList.length ? nodeList.length : shown.length + ' / ' + nodeList.length) + ' 个节点';
      $('node-config').textContent = nodeConfig ? '当前配置：' + nodeConfig : '';
      $('node-selected').textContent = selected ? '已选：' + selected : '尚未选择节点';
      if (nodeLoading || !shown.length) {
        var empty = document.createElement('div'); empty.className = 'oc-mp-node-empty';
        empty.textContent = nodeLoading ? '正在读取当前配置中的节点…' : nodeList.length ? '没有匹配的节点' : '当前配置没有可展示的代理节点';
        grid.appendChild(empty); pickerControls(); return;
      }
      shown.forEach(function (n) {
        var card = document.createElement('article'); card.className = 'oc-mp-node-card';
        card.setAttribute('data-node-name', n.name);
        card.classList.toggle('oc-mp-node-chosen', n.name === selected);
        card.classList.toggle('oc-mp-node-unavailable', !n.available);
        var select = document.createElement('button'); select.type = 'button'; select.className = 'oc-mp-node-select';
        select.disabled = !n.available; select.setAttribute('aria-pressed', String(n.name === selected));
        select.setAttribute('aria-label', '选择节点 ' + n.name);
        var titleRow = document.createElement('span'); titleRow.className = 'oc-mp-node-title-row';
        var name = document.createElement('strong'); name.className = 'oc-mp-node-name'; name.textContent = n.name; name.title = n.name; titleRow.appendChild(name);
        if (n.name === selected) {
          var ns = 'http://www.w3.org/2000/svg', check = document.createElementNS(ns, 'svg');
          check.setAttribute('class', 'oc-mp-node-check'); check.setAttribute('viewBox', '0 0 24 24');
          check.setAttribute('width', '18'); check.setAttribute('height', '18'); check.setAttribute('aria-hidden', 'true');
          check.setAttribute('fill', 'none'); check.setAttribute('stroke', 'currentColor'); check.setAttribute('stroke-width', '1.8');
          check.setAttribute('stroke-linecap', 'round'); check.setAttribute('stroke-linejoin', 'round');
          var circle = document.createElementNS(ns, 'circle'); circle.setAttribute('cx', '12'); circle.setAttribute('cy', '12'); circle.setAttribute('r', '9');
          var path = document.createElementNS(ns, 'path'); path.setAttribute('d', 'm8 12 3 3 5-6');
          check.appendChild(circle); check.appendChild(path); titleRow.appendChild(check);
        }
        select.appendChild(titleRow);
        var protocol = document.createElement('span'); protocol.className = 'oc-mp-node-protocol';
        var type = document.createElement('span'); type.className = 'oc-mp-node-type'; type.textContent = (n.type || '-').toUpperCase(); protocol.appendChild(type);
        if (!n.available) { var unavailable = document.createElement('span'); unavailable.className = 'oc-mp-node-offline'; unavailable.textContent = '未加载'; protocol.appendChild(unavailable); }
        select.appendChild(protocol);
        function detail(label, text, title) {
          var line = document.createElement('span'); line.className = 'oc-mp-node-detail';
          var key = document.createElement('span'); key.textContent = label;
          var value = document.createElement('span'); value.textContent = text; value.title = title || text;
          line.appendChild(key); line.appendChild(value); select.appendChild(line);
        }
        detail('server', n.server || '-');
        var ip = nodeIPs[n.name];
        detail('IP', ip && ip.pending ? '解析中…' : ip && ip.ip || n.ip || '-', '节点服务器的 DNS 解析结果；不是出口 IP，也不保证是实际连接地址');
        select.addEventListener('click', function () {
          $('node').value = n.name; $('error').textContent = ''; $('node-dialog').close();
        });
        card.appendChild(select);
        var metrics = document.createElement('div'); metrics.className = 'oc-mp-node-metrics';
        var state = nodeDelays[n.name], delay = state ? state.delay : n.delay;
        var tag = document.createElement('button'); tag.type = 'button'; tag.className = 'oc-mp-delay-tag';
        tag.disabled = !n.available || !!(state && state.pending);
        if (state && state.pending) {
          tag.classList.add('oc-mp-delay-loading');
          var spinner = document.createElement('span'); spinner.className = 'oc-mp-delay-spinner'; tag.appendChild(spinner);
          tag.title = '正在检测此节点…';
        } else {
          tag.classList.add(delay === null ? 'oc-mp-delay-empty' : 'oc-mp-delay-' + (delay <= 200 ? 'low' : delay <= 500 ? 'medium' : 'high'));
          tag.textContent = delay === null ? '-' : delay + ' ms';
          tag.title = !n.available ? '节点尚未加载到内核' : state && state.note ? state.note :
            (state ? '本次节点测速' : '内核最近一次测速记录') + '；点击通过内核检测此节点到 Google 204 的延迟';
        }
        tag.setAttribute('aria-label', n.name + '：' + tag.title);
        tag.addEventListener('click', function () { refreshNodeDelays(n.name); });
        metrics.appendChild(tag); card.appendChild(metrics); grid.appendChild(card);
        if (n.name === focusedName) {
          var focusTarget = focusedDelay ? tag : select;
          if (!focusTarget.disabled) focusTarget.focus({preventScroll: true});
        }
      });
      grid.scrollTop = scrollTop;
      pickerControls();
    }
    function drainNodeJobs() {
      while (nodeActive < 3 && nodeJobs.length) {
        var job = nodeJobs.shift();
        if (job.epoch !== nodeEpoch || !$('node-dialog').open) continue;
        nodeActive++; runNodeJob(job);
      }
    }
    async function runNodeJob(job) {
      try {
        var result = await request(job.action, {name: job.name, config: job.config});
        if (job.epoch === nodeEpoch && $('node-dialog').open) {
          if (job.action === 'node_delay') nodeDelays[job.name] = {pending: false, delay: result.delay, note: result.note};
          else job.names.forEach(function (name) { nodeIPs[name] = {pending: false, ip: result.ip}; });
        }
      } catch (error) {
        if (job.epoch === nodeEpoch && $('node-dialog').open) {
          if (job.action === 'node_delay') nodeDelays[job.name] = {pending: false, delay: null, note: error.message};
          else job.names.forEach(function (name) { nodeIPs[name] = {pending: false, ip: null}; });
        }
      } finally {
        nodeActive--; drainNodeJobs();
        if (job.epoch === nodeEpoch && $('node-dialog').open) renderNodes();
      }
    }
    function refreshNodeDelays(name) {
      if (nodeLoading) return;
      (name ? nodeList.filter(function (n) { return n.name === name; }) : visibleNodes()).forEach(function (n) {
        if (!n.available || (nodeDelays[n.name] && nodeDelays[n.name].pending)) return;
        nodeDelays[n.name] = {pending: true, delay: null};
        // A clicked delay takes priority over background IP lookups.
        var index = nodeJobs.findIndex(function (job) { return job.action === 'node_ip'; });
        nodeJobs.splice(index < 0 ? nodeJobs.length : index, 0, {action: 'node_delay', name: n.name, config: nodeConfig, epoch: nodeEpoch});
      });
      renderNodes(); drainNodeJobs();
    }
    async function loadNodes() {
      var epoch = ++nodeEpoch;
      nodeJobs = []; nodeList = []; nodeConfig = ''; nodeDelays = Object.create(null); nodeIPs = Object.create(null);
      nodeLoading = true; pickerMessage(''); renderNodes();
      try {
        var result = await request('nodes');
        if (epoch !== nodeEpoch || !$('node-dialog').open) return;
        nodeList = result.nodes; nodeConfig = result.config;
        pickerMessage(Array.isArray(result.warnings) ? result.warnings.join(' ') : '');
        var servers = Object.create(null);
        nodeList.forEach(function (n) {
          if (n.available && n.server && !n.ip) {
            nodeIPs[n.name] = {pending: true, ip: null};
            if (servers[n.server]) servers[n.server].names.push(n.name);
            else {
              var job = {action: 'node_ip', name: n.name, names: [n.name], config: nodeConfig, epoch: epoch};
              servers[n.server] = job; nodeJobs.push(job);
            }
          }
        });
      } catch (error) {
        if (epoch === nodeEpoch && $('node-dialog').open) pickerMessage(error.message);
      } finally {
        if (epoch === nodeEpoch && $('node-dialog').open) { nodeLoading = false; renderNodes(); drainNodeJobs(); }
      }
    }
    function openNodePicker() {
      if (busy) return;
      $('node-search').value = ''; $('node-dialog').showModal(); $('node-search').focus(); loadNodes();
    }
    function generatePassword() {
      if (!window.crypto || !window.crypto.getRandomValues) {
        $('error').textContent = '当前浏览器无法生成密码，请手动填写。';
        return '';
      }
      var alphabet = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz', password;
      // Rejection sampling keeps all 62 characters equally likely.
      do {
        password = '';
        while (password.length < 8) {
          var bytes = new Uint8Array(16); window.crypto.getRandomValues(bytes);
          for (var i = 0; i < bytes.length && password.length < 8; i++) {
            if (bytes[i] < 248) password += alphabet[bytes[i] % 62];
          }
        }
      } while (!/[0-9]/.test(password) || !/[A-Z]/.test(password) || !/[a-z]/.test(password));
      return password;
    }
    function setPasswordVisible(visible) {
      $('password').type = visible ? 'text' : 'password';
      var toggle = $('toggle-password'), text = visible ? '隐藏密码' : '显示密码';
      toggle.title = text; toggle.setAttribute('aria-label', text);
      toggle.setAttribute('aria-pressed', String(visible));
      $('password-eye-slash').toggleAttribute('hidden', !visible);
    }
    function open(id) {
      if (!ready || busy) return;
      editing = id || null; var e = entries.find(function (x) { return x.id === id; });
       $('error').textContent = ''; $('dialog-title').textContent = e ? '编辑代理配置' : '新增代理配置';
      var mixedHost = defaultInfo().address.match(/^([0-9.]+):\d+$/);
      $('host').value = e ? e.host : (mixedHost ? mixedHost[1] : window.location.hostname);
      var next = 17893; while (defaultInfo().port === next || entries.some(function (x) { return x.port === next; })) next++;
      $('port').value = e ? e.port : next; $('node').value = e ? e.node : '';
      $('username').value = e && typeof e.username === 'string' ? e.username : 'Clash';
      $('password').value = e ? (e.password || '') : generatePassword();
      setPasswordVisible(false);
      $('dialog').showModal(); $('host').focus();
    }
    function copy(text, btn) {
      // Same helper and success checkmark as the control panel. No prompt on failure.
      if (typeof window.ocCopyToClipboard === 'function') {
        window.ocCopyToClipboard(text, btn);
        return;
      }
      function fallback() {
        var ta = document.createElement('textarea'); ta.value = text;
        ta.style.cssText = 'position:fixed;top:0;left:0;opacity:0'; document.body.appendChild(ta); ta.select();
        var ok = false;
        try { ok = document.execCommand('copy'); } catch (e) {}
        ta.remove();
        if (btn) btn.title = ok ? '已复制' : '复制失败，请检查浏览器剪贴板权限';
      }
      if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(function () {
        if (btn) btn.title = '已复制';
      }, fallback);
      else fallback();
    }
    $('confirm').addEventListener('click', async function (event) {
      event.preventDefault();
      if (!ready || busy) return;
      $('error').textContent = '';
      if (['host', 'port', 'node', 'username', 'password'].some(function (id) { return !$(id).reportValidity(); })) return;
      var port = Number($('port').value), host = $('host').value.trim();
      var label = host + ':' + port, node = $('node').value;
      var username = $('username').value.trim(), password = $('password').value;
      if (!username || !password) { $('error').textContent = '请填写认证账号和密码。'; return; }
      if (/:|[\r\n]/.test(username) || /[\r\n]/.test(password)) { $('error').textContent = '账号不能包含冒号或换行，密码不能包含换行。'; return; }
      if (!node || !host) { $('error').textContent = '请填写代理服务器，并选择出口节点。'; return; }
      if (!/^(\d{1,3}\.){3}\d{1,3}$/.test(host) || host.split('.').some(function (n) { return Number(n) > 255; })) { $('error').textContent = '请填写路由器本机 IPv4 地址，例如 192.168.2.2。'; return; }
      if (defaultInfo().port === port || entries.some(function (x) { return x.port === port && x.id !== editing; })) { $('error').textContent = '该端口已存在，请选择其他端口。'; return; }
      if (!editing && entries.length >= 100) { $('error').textContent = '最多添加 100 个入口。'; return; }
      var e = { id: editing || ('mp_' + Date.now() + '_' + Math.random().toString(36).slice(2, 8)), label: label, host: host, port: port, node: node, username: username, password: password, enabled: editing ? entries.find(function (x) { return x.id === editing; }).enabled : true };
      if (!valid(e)) { $('error').textContent = '端口须为 1024 到 65535 之间的整数。'; return; }
      var next = editing ? entries.map(function (x) { return x.id === editing ? e : x; }) : entries.concat([e]);
      try { if (await persist(next)) $('dialog').close(); }
      catch (error) { $('error').textContent = error.message; }
    });
    $('toggle-password').addEventListener('click', function () { setPasswordVisible($('password').type === 'password'); });
    $('choose-node').addEventListener('click', openNodePicker);
    $('node').addEventListener('click', openNodePicker);
    $('node-search').addEventListener('input', renderNodes);
    $('node-reload').addEventListener('click', loadNodes);
    $('node-refresh').addEventListener('click', function () { refreshNodeDelays(); });
    $('node-close').addEventListener('click', function () { $('node-dialog').close(); });
    $('node-dialog').addEventListener('close', function () {
      nodeEpoch++; nodeJobs = []; nodeLoading = false; $('choose-node').focus();
    });
    $('dialog').addEventListener('close', function () { setPasswordVisible(false); });
    $('dialog').addEventListener('cancel', function (event) { if (busy) event.preventDefault(); });
    $('generate-password').addEventListener('click', function () {
      var password = generatePassword();
      if (password) { $('password').value = password; $('error').textContent = ''; }
    });
    $('add').addEventListener('click', function () { open(); });
    $('refresh').addEventListener('click', function () { refreshDelays(); });
    var modeControls = document.getElementById('radio-mode');
    if (modeControls) modeControls.addEventListener('change', function () {
      // A mode switch changes the default port's policy, not custom listeners.
      delete latencies.default; controls(); render();
    });
    ['cancel', 'cancel-x'].forEach(function (id) { $(id).addEventListener('click', function () { $('dialog').close(); }); });
    controls(); render();
    request('state').then(function (result) {
      accept(result); controls(); render();
      scheduleAutomaticProbes();
    }).catch(function (error) { message(error.message); });
    // Reuse the real mixed-port address updated by OpenClash's existing status script.
    var observer = new MutationObserver(function () { render(); runInitialProbes(); });
    ['_mix_proxy', '_clash'].forEach(function (id) {
      var el = document.getElementById(id);
      if (el) observer.observe(el, { childList: true, characterData: true, subtree: true });
    });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init); else init();
}());
