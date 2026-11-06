# OC_MULTIPORT_BACKEND_V8 (only OpenClash's existing YAML library)
# Invoked by the authenticated LuCI controller, or the OpenClash startup hook.
require 'yaml'

module OCMultiport
  STORE = '/etc/openclash/custom/oc-multiport.json'
  ROOT = '/etc/openclash'
  PREFIX = 'oc-mp-managed-'
  # Match OpenClash's procd environment when testing its runtime configuration.
  CORE_ENV = {'SAFE_PATHS'=>'/usr/share/openclash:/etc/ssl'}.freeze
  DELAY_URL = 'https://www.gstatic.com/generate_204'
  class Failure < StandardError; end
  class Conflict < Failure; end
  module_function

  # JSON is a YAML subset. Safe loading rejects objects and aliases; only plain
  # data is accepted by validate(). No ruby-json package is needed.
  def decode(text)
    YAML.safe_load(text, permitted_classes: [], permitted_symbols: [], aliases: false)
  end

  def encode(value)
    case value
    when Hash then '{' + value.map { |k,v| encode(k.to_s) + ':' + encode(v) }.join(',') + '}'
    when Array then '[' + value.map { |v| encode(v) }.join(',') + ']'
    when String
      '"' + value.gsub(/["\\\x00-\x1f]/) { |c| c == '"' ? '\\"' : c == '\\' ? '\\\\' : '\\u%04x' % c.ord } + '"'
    when Integer then value.to_s
    when TrueClass then 'true'
    when FalseClass then 'false'
    when NilClass then 'null'
    else raise Failure, '接口包含不支持的数据类型'
    end
  end

  # Exclusive creation and mode 600 protect passwords without ruby-tempfile.
  class ScratchFile
    attr_reader :path
    def initialize(prefix, directory='/tmp')
      20.times do
        @path = File.join(directory, "#{Array(prefix).join}#{Process.pid}-#{rand(1 << 60)}")
        begin
          @file = File.open(@path, File::RDWR|File::CREAT|File::EXCL, 0600)
          return
        rescue Errno::EEXIST
        end
      end
      raise Failure, '无法创建临时文件'
    end
    def chmod(mode); @file.chmod(mode); end
    def write(value); @file.write(value); end
    def flush; @file.flush; end
    def fsync; @file.fsync; end
    def close!
      @file.close if @file && !@file.closed?
      File.unlink(@path) if @path && File.exist?(@path)
    end
  end

  def capture(*arguments, stdin_data: nil, capture_stderr: false, environment: {})
    output = ScratchFile.new('oc-mp-output-')
    input, errors = nil, nil
    begin
      errors = capture_stderr && ScratchFile.new('oc-mp-errors-')
      input = stdin_data && ScratchFile.new('oc-mp-input-')
      if input
        input.write(stdin_data); input.flush
      end
      # Array-form system never passes arguments through a shell.
      system(environment, *arguments, in: input ? input.path : File::NULL, out: output.path, err: errors ? errors.path : File::NULL)
      status = $?
      [File.read(output.path), errors ? File.read(errors.path) : '', status]
    ensure
      output.close!
      input.close! if input
      errors.close! if errors
    end
  end

  def check_failure_detail(output, errors, config, entries)
    text = (output.to_s + "\n" + errors.to_s).encode('UTF-8', invalid: :replace, undef: :replace)
    text = text.gsub(/\e\[[0-9;]*[A-Za-z]/, '')
    # Core diagnostics can quote configuration values; redact before returning.
    secrets = entries.map { |e| e['password'] }
    collect = lambda do |value, sensitive=false|
      case value
      when Hash
        value.each { |key, item| collect.call(item, sensitive || key.to_s.match?(/password|secret|token|uuid|private.key|authentication/i)) }
      when Array then value.each { |item| collect.call(item, sensitive) }
      when String
        if sensitive
          secrets << value
          secrets << value.split(':', 2).last if value.include?(':')
        end
      end
    end
    collect.call(config)
    secrets.compact.reject(&:empty?).uniq.sort_by { |s| -s.length }.each { |s| text = text.gsub(s, '[已隐藏]') }
    text = text.gsub(%r{https?://[^\s"'<>]+}i, '[链接已隐藏]')
    text = text.gsub(/[\x00-\x08\x0b-\x1f\x7f]/, '')
    lines = text.lines.map(&:strip).reject(&:empty?)
    relevant = lines.select { |line| line.match?(/error|fatal|panic|failed|invalid|unsupported|not found|unmarshal|配置|错误/i) }
    detail = (relevant.empty? ? lines : relevant).last(6).join("\n")[0, 1800]
    detail.empty? ? '内核没有输出错误详情，请确认 /etc/openclash/clash 可执行且内存充足' : detail
  end

  def local_ips
    previous = nil; ips = []
    File.foreach('/proc/net/fib_trie') do |line|
      match = line.match(/\|--\s+(\d+\.\d+\.\d+\.\d+)/)
      previous = match[1] if match
      ips << previous if previous && line.include?('/32 host LOCAL')
    end
    ips.uniq
  end

  def endpoints
    %w[tcp udp tcp6 udp6].flat_map do |kind|
      path = '/proc/net/' + kind
      next [] unless File.exist?(path)
      File.readlines(path).drop(1).map do |line|
        fields = line.split
        next unless fields[1] && (kind.start_with?('udp') || fields[3] == '0A')
        address, port = fields[1].split(':')
        {'kind'=>kind, 'address'=>address, 'port'=>port.to_i(16)}
      end.compact
    end
  end

  def read_yaml(path)
    # OpenClash's own files may contain Ruby YAML aliases.
    value = YAML.respond_to?(:unsafe_load_file) ? YAML.unsafe_load_file(path) : YAML.load_file(path)
    raise Failure, 'OpenClash 配置格式错误' unless value.is_a?(Hash)
    value
  end

  def atomic(path, content)
    tmp = ScratchFile.new(['.oc-mp-', '.tmp'], File.dirname(path))
    begin
      tmp.chmod(0600)
      tmp.write(content)
      tmp.flush
      tmp.fsync
      File.rename(tmp.path, path)
    ensure
      tmp.close!
    end
  end

  def saved
    return {'revision'=>0, 'entries'=>[]} unless File.exist?(STORE)
    data = decode(File.read(STORE))
    raise Failure, '代理配置存储损坏，请检查 oc-multiport.json' unless data['entries'].is_a?(Array) && data['revision'].is_a?(Integer)
    data
  end

  def runtime_path
    path, _, status = capture('uci', '-q', 'get', 'openclash.config.config_path')
    raise Failure, '未找到当前 OpenClash 配置' unless status.success? && !path.strip.empty?
    result = File.join(ROOT, File.basename(path.strip))
    raise Failure, 'OpenClash 尚未生成运行配置，请先启动插件' unless File.file?(result)
    result
  end

  def validate(entries)
    raise Failure, '端口配置必须是列表，最多 100 项' unless entries.is_a?(Array) && entries.size <= 100
    ids, ports = [], []
    entries.map do |raw|
      raise Failure, '入口数据格式错误' unless raw.is_a?(Hash)
      e = raw.select { |k, _| %w[id host port node username password enabled].include?(k) }
      %w[id host node username password].each do |key|
        raise Failure, '请完整填写地址、节点、账号和密码' unless e[key].is_a?(String) && !e[key].empty? && e[key].bytesize <= 1024
        raise Failure, '字段不能包含换行或控制字符' if e[key].match?(/[\x00-\x1f\x7f]/)
      end
      raise Failure, '入口标识不合法' unless e['id'].match?(/\Amp_[a-zA-Z0-9_]{1,80}\z/)
      raise Failure, '账号不能包含冒号' if e['username'].include?(':')
      ipv4 = e['host'].match?(/\A(?:\d{1,3}\.){3}\d{1,3}\z/) && e['host'].split('.').all? { |part| part.to_i <= 255 && part.to_i.to_s == part }
      raise Failure, '代理服务器请填写路由器本机的 IPv4 地址' unless ipv4 && !%w[0.0.0.0 255.255.255.255].include?(e['host'])
      raise Failure, '端口范围为 1024–65535' unless e['port'].is_a?(Integer) && (1024..65535).include?(e['port'])
      raise Failure, '启用状态格式错误' unless [true, false].include?(e['enabled'])
      raise Failure, '入口标识或端口重复' if ids.include?(e['id']) || ports.include?(e['port'])
      ids << e['id']; ports << e['port']
      e['label'] = "#{e['host']}:#{e['port']}"
      e
    end
  end

  def listeners(entries)
    entries.select { |e| e['enabled'] }.map do |e|
      {'name'=>PREFIX + e['id'], 'type'=>'mixed', 'listen'=>e['host'], 'port'=>e['port'],
       'udp'=>true, 'proxy'=>e['node'], 'users'=>[{'username'=>e['username'], 'password'=>e['password']}]}
    end
  end

  def merge(config, entries)
    result = Marshal.load(Marshal.dump(config))
    existing = result.fetch('listeners', [])
    raise Failure, '原配置 listeners 格式错误' unless existing.is_a?(Array)
    existing = existing.reject { |l| l.is_a?(Hash) && l['name'].to_s.start_with?(PREFIX) }
    reserved = %w[port socks-port mixed-port redir-port tproxy-port].map { |k| result[k].to_i }.reject(&:zero?)
    reserved += existing.filter_map { |l| l.is_a?(Hash) ? Integer(l['port'], exception: false) : nil }
    entries.each { |e| raise Failure, "端口 #{e['port']} 与 OpenClash 已有端口冲突" if reserved.include?(e['port']) }
    result['listeners'] = existing + listeners(entries)
    result
  end

  def api(config, method, endpoint, body=nil, timeout=20)
    controller = config['external-controller'].to_s
    raise Failure, '请先开启内核 HTTP 控制接口' unless controller.match?(/\A(?:\[[0-9a-fA-F:]+\]|[a-zA-Z0-9.-]+):\d+\z/)
    controller = controller.sub(/\A(?:0\.0\.0\.0|\[::\]):/, '127.0.0.1:')
    secret = config['secret'].to_s
    raise Failure, '控制接口密钥包含不支持的换行' if secret.match?(/[\r\n]/)
    options = ['curl', '--disable', '--silent', '--show-error', '--noproxy', '*', '--connect-timeout', '3', '--max-time', timeout.to_s,
               '--config', '-', '--request', method, '--write-out', "\n%{http_code}", "http://#{controller}#{endpoint}"]
    payload = body && ScratchFile.new(['oc-mp-api-', '.json'])
    begin
      if payload
        payload.chmod(0600); payload.write(encode(body)); payload.flush
        options += ['--header', 'Content-Type: application/json', '--data-binary', '@' + payload.path]
      end
      output, _, status = capture(*options, stdin_data: "header = #{encode('Authorization: Bearer ' + secret)}\n")
      text, _, code = output.rpartition("\n")
      raise Failure, '无法连接内核接口，请确认 OpenClash 已运行' unless status.success? && code.to_i.between?(200,299)
      text.empty? ? {} : decode(text)
    ensure
      payload.close! if payload
    end
  end

  def url_component(value)
    value.to_s.encode('UTF-8').bytes.map { |b| (b.between?(65,90) || b.between?(97,122) || b.between?(48,57) || [45,46,95,126].include?(b)) ? b.chr : '%%%02X' % b }.join
  end

  def ip_literal?(value)
    return false unless value.is_a?(String)
    ipv4 = value.match?(/\A(?:\d{1,3}\.){3}\d{1,3}\z/) && value.split('.').all? { |p| p.to_i <= 255 && p.to_i.to_s == p }
    # IPv6 is display-only here; never interpolated into a shell or URL.
    ipv4 || (value.include?(':') && value.match?(/\A[0-9a-fA-F:.]+\z/))
  end

  def node_catalog(config)
    live = api(config, 'GET', '/proxies', nil, 8).fetch('proxies', {})
    raise Failure, '内核节点列表格式错误' unless live.is_a?(Hash)
    raw = Array(config['proxies']).select { |n| n.is_a?(Hash) }
    warnings = []
    providers = config.fetch('proxy-providers', {})
    raise Failure, '当前配置 proxy-providers 格式错误' unless providers.is_a?(Hash)
    providers.each_value do |provider|
      next unless provider.is_a?(Hash)
      payload = provider['payload']
      if payload.is_a?(Array)
        raw.concat(payload.select { |n| n.is_a?(Hash) })
      elsif provider['path'].is_a?(String)
        begin
          path = File.expand_path(provider['path'], ROOT)
          # Only read the configured provider cache inside OpenClash's folder.
          # Resolve symlinks as well; never fetch a subscription URL here.
          real = File.realpath(path)
          raise Failure unless real.start_with?(File.realpath(ROOT) + '/')
          content = read_yaml(real)
          raw.concat(Array(content['proxies']).select { |n| n.is_a?(Hash) })
        rescue StandardError
          warnings << '部分订阅节点的 server 详情暂不可读取，仍可选择已加载的节点。'
        end
      end
    end
    groups = Array(config['proxy-groups']).filter_map { |g| g.is_a?(Hash) ? g['name'] : nil }
    leaf = lambda do |name, n|
      name.is_a?(String) && !name.empty? && !groups.include?(name) && n.is_a?(Hash) &&
        !n['all'].is_a?(Array) && !%w[direct reject rejectdrop pass compatible dns selector urltest fallback loadbalance relay].include?(n['type'].to_s.downcase.delete('-_'))
    end
    records = {}
    raw.each do |n|
      name = n['name']
      next unless leaf.call(name, n)
      server = n['server'].is_a?(String) ? n['server'] : nil
      records[name] = {'name'=>name, 'type'=>n['type'].to_s.upcase, 'server'=>server,
        'port'=>Integer(n['port'], exception: false), 'ip'=>ip_literal?(server) ? server : nil}
    end
    # Provider nodes can be loaded in memory before their cache is readable.
    live.each do |name, n|
      next unless leaf.call(name, n)
      records[name] ||= {'name'=>name, 'type'=>n['type'].to_s.upcase, 'server'=>nil, 'port'=>nil, 'ip'=>nil}
    end
    records.each do |name, n|
      info = live[name]
      n['available'] = !!(info && leaf.call(name, info))
      last = info.is_a?(Hash) && info['history'].is_a?(Array) ? info['history'].last : nil
      d = last.is_a?(Hash) ? last['delay'] : nil
      n['delay'] = d.is_a?(Integer) && d.between?(1,65535) ? d : nil
    end
    [records.values, warnings.uniq]
  end

  def nodes
    path = runtime_path
    list, warnings = node_catalog(read_yaml(path))
    raise Conflict, '当前配置已切换，请刷新节点列表' unless runtime_path == path
    {'ok'=>true, 'config'=>File.basename(path), 'nodes'=>list, 'warnings'=>warnings}
  end

  def selected_node(request)
    raise Failure, '节点参数格式错误' unless request.is_a?(Hash) && request['name'].is_a?(String) && request['name'].bytesize.between?(1,1024)
    path = runtime_path
    raise Conflict, '当前配置已切换，请刷新节点列表' unless request['config'] == File.basename(path)
    config = read_yaml(path)
    list, = node_catalog(config)
    node = list.find { |n| n['name'] == request['name'] }
    raise Failure, '节点已移除或尚未加载，请刷新节点列表' unless node && node['available']
    [config, node, path]
  end

  def node_delay(request)
    config, node, path = selected_node(request)
    begin
      value = api(config, 'GET', '/proxies/' + url_component(node['name']) + '/delay?url=' + url_component(DELAY_URL) + '&timeout=5000', nil, 8)
      d = value.is_a?(Hash) ? value['delay'] : nil
      result = {'delay'=>d.is_a?(Integer) && d.between?(1,65535) ? d : nil}
    rescue Failure
      result = {'delay'=>nil, 'note'=>'节点连接失败或测速超时'}
    end
    raise Conflict, '当前配置已切换，请刷新节点列表' unless runtime_path == path
    {'ok'=>true, 'name'=>node['name']}.merge(result)
  end

  def node_ip(request)
    config, node, path = selected_node(request)
    ip = node['ip']
    server = node['server']
    if !ip && server.is_a?(String) && server.bytesize <= 253 && server.match?(/\A[a-zA-Z0-9._-]+\z/)
      %w[A AAAA].each do |type|
        begin
          answer = api(config, 'GET', '/dns/query?name=' + url_component(server) + '&type=' + type, nil, 6)
          item = Array(answer['Answer']).find { |a| a.is_a?(Hash) && [1,28].include?(a['type']) && ip_literal?(a['data']) }
          ip = item['data'] if item
        rescue Failure
          # DNS is optional information. Failure must not prevent selection.
        end
        break if ip
      end
    end
    raise Conflict, '当前配置已切换，请刷新节点列表' unless runtime_path == path
    {'ok'=>true, 'name'=>node['name'], 'ip'=>ip}
  end

  def listening?(entry)
    # /proc prints IPv4 words in native byte order (also supports MIPS routers).
    address = '%08X' % entry['host'].split('.').map(&:to_i).pack('C4').unpack1('L')
    active = endpoints
    %w[tcp udp].all? { |kind| active.any? { |p| p['kind'] == kind && p['address'] == address && p['port'] == entry['port'] } }
  end

  def state
    data = saved
    config = read_yaml(runtime_path)
    active = config.fetch('listeners', [])
    available = true
    begin
      api(config, 'GET', '/version')
    rescue Failure
      available = false
    end
    current = data['entries'].map do |entry|
      e = entry.dup
      expected = listeners([entry]).first
      e['applied'] = available && (entry['enabled'] ? active.include?(expected) && listening?(entry) : !active.any? { |l| l['name'] == PREFIX + entry['id'] })
      e
    end
    {'ok'=>true, 'revision'=>data['revision'], 'entries'=>current}
  end

  def probe(entry)
    # This is a real request through THIS mixed port, not a node /delay API.
    # Disable curlrc and bypass lists so a failed proxy cannot fall back direct.
    options = ['curl', '--disable', '--silent', '--show-error', '--noproxy', '',
               '--connect-timeout', '3', '--max-time', '8', '--config', '-',
               '--proxy', "http://#{entry['host']}:#{entry['port']}", '--proxy-basic',
               '--output', File::NULL, '--max-filesize', '4096',
               '--write-out', "\nOC_MP_METRICS:%{http_code}:%{time_total}", DELAY_URL]
    # Credentials stay out of argv/process listings, in private temporary stdin.
    auth = entry['username'] && entry['password'] ? "#{entry['username']}:#{entry['password']}" : nil
    input = auth ? "proxy-user = #{encode(auth)}\n" : ''
    output, _, status = capture(*options, stdin_data: input)
    _, separator, metrics = output.rpartition("\nOC_MP_METRICS:")
    code, elapsed = metrics.strip.split(':', 2)
    if status && status.success? && !separator.empty? && code == '204' && elapsed.to_s.match?(/\A\d+(?:\.\d+)?\z/)
      milliseconds = (elapsed.to_f * 1000).round
      return {'delay'=>milliseconds} if milliseconds.between?(0, 8000)
    end
    {'delay'=>nil, 'note'=>code == '407' ? '代理认证失败' : '连接失败、超时或测试地址不可达'}
  end

  def delay(request)
    raise Failure, '延迟检测参数格式错误' unless request.is_a?(Hash) && request['id'].is_a?(String)
    data = saved
    raise Conflict, '配置已变化，请刷新页面后重新检测' unless request['revision'] == data['revision']
    path = runtime_path
    original = File.binread(path)
    config = read_yaml(path)
    id = request['id']
    if id == 'default'
      # Only the displayed local address is accepted; the port/auth come from
      # the running configuration, never client-supplied credentials or ports.
      host = request['host']
      raise Failure, '默认代理地址不是路由器本机 IPv4 地址' unless host.is_a?(String) && local_ips.include?(host)
      port = Integer(config['mixed-port'], exception: false)
      raise Failure, '当前配置没有启用混合代理端口' unless port && (1..65535).include?(port)
      entry = {'host'=>host, 'port'=>port}
      auth = config.fetch('authentication', [])
      raise Failure, '默认代理认证配置格式错误' unless auth.is_a?(Array)
      unless auth.empty?
        username, password = auth.first.to_s.split(':', 2)
        raise Failure, '默认代理认证配置格式错误' unless username && password
        entry['username'], entry['password'] = username, password
      end
      result = probe(entry)
    else
      entry = data['entries'].find { |e| e['id'] == id }
      raise Failure, '未找到该代理入口，请刷新页面' unless entry
      if !entry['enabled']
        result = {'delay'=>nil, 'note'=>'代理已停用'}
      elsif !config.fetch('listeners', []).include?(listeners([entry]).first) || !listening?(entry)
        result = {'delay'=>nil, 'note'=>'入口尚未应用到内核'}
      else
        raise Failure, '代理地址已不是路由器本机地址，请重新配置' unless local_ips.include?(entry['host'])
        result = probe(entry)
      end
    end
    raise Conflict, '检测期间配置已变化，请刷新页面后重试' unless saved['revision'] == data['revision'] && runtime_path == path && File.binread(path) == original
    {'ok'=>true, 'id'=>id, 'revision'=>data['revision']}.merge(result)
  end

  def apply(request)
    old = saved
    raise Conflict, '配置已被其他页面修改，请刷新后重试' unless request['revision'] == old['revision']
    entries = validate(request['entries'])
    path = runtime_path
    original = File.binread(path)
    config = read_yaml(path)
    proxies = api(config, 'GET', '/proxies').fetch('proxies', {})
    addresses = local_ips
    entries.each do |e|
      raise Failure, "#{e['host']} 不是路由器本机地址" unless addresses.include?(e['host'])
      next unless e['enabled']
      raise Failure, "找不到节点或策略组：#{e['node']}" unless proxies.key?(e['node'])
      previous = old['entries'].find { |p| p['enabled'] && p['id'] == e['id'] && p['host'] == e['host'] && p['port'] == e['port'] }
      next if previous
      raise Failure, "端口 #{e['port']} 已被其他服务占用" if endpoints.any? { |p| p['port'] == e['port'] }
    end
    candidate = merge(config, entries)
    tmp = ScratchFile.new(['.oc-mp-check-', '.yaml'], ROOT)
    begin
      tmp.chmod(0600); tmp.write(YAML.dump(candidate)); tmp.flush
      output, errors, status = capture(File.join(ROOT, 'clash'), '-t', '-d', ROOT, '-f', tmp.path, capture_stderr: true, environment: CORE_ENV)
      unless status && status.success?
        code = status && status.exitstatus
        detail = check_failure_detail(output, errors, config, entries)
        raise Failure, "内核配置校验失败#{code ? '（退出码 ' + code.to_s + '）' : ''}，未修改原配置：\n#{detail}"
      end
    ensure
      tmp.close!
    end
    raise Conflict, 'OpenClash 配置刚刚发生变化，请刷新后重试' unless runtime_path == path && File.binread(path) == original
    changed = false
    begin
      changed = true
      atomic(path, YAML.dump(candidate))
      api(config, 'PUT', '/configs?force=true', {'path'=>path})
      raise Failure, '内核加载后未检测到新增监听端口' unless entries.all? { |e| !e['enabled'] || listening?(e) }
      atomic(STORE, encode({'revision'=>old['revision'] + 1, 'entries'=>entries}))
    rescue StandardError => error
      if changed
        begin
          atomic(path, original)
          api(config, 'PUT', '/configs?force=true', {'path'=>path})
        rescue StandardError
          raise Failure, '应用失败，已尝试恢复配置但无法确认内核回滚，请重启 OpenClash'
        end
      end
      raise Failure, "#{error.is_a?(Failure) ? error.message : '保存配置失败'}，已恢复原配置"
    end
    {'ok'=>true, 'revision'=>old['revision'] + 1, 'entries'=>entries.map { |e| e.merge('applied'=>true) }}
  end

  def run
    if ARGV[0] == 'merge'
      path = ARGV.fetch(1)
      atomic(path, YAML.dump(merge(read_yaml(path), validate(saved['entries']))))
      return
    end
    if %w[delay nodes node_delay node_ip].include?(ARGV[0])
      # Read-only probes run independently; do not hold the apply lock while
      # waiting for the network. Atomic snapshots/revision checks reject races.
      result = ARGV[0] == 'nodes' ? nodes : public_send(ARGV[0], decode(File.read(ARGV.fetch(1))))
      puts encode(result)
      return
    end
    Dir.mkdir('/var/lock', 0755) unless File.directory?('/var/lock')
    File.open('/var/lock/oc-multiport.lock', File::RDWR|File::CREAT, 0600) do |lock|
      raise Failure, '其他操作正在应用，请稍后重试' unless lock.flock(File::LOCK_EX|File::LOCK_NB)
      result = case ARGV[0]
               when 'state' then state
               when 'apply' then apply(decode(File.read(ARGV.fetch(1))))
               else raise Failure, '不支持的操作'
               end
      puts encode(result)
    end
  rescue StandardError => error
    if ARGV[0] == 'merge'
      warn 'OpenClash 多端口配置合并失败，请检查已保存配置'
      exit 1
    end
    puts encode({'ok'=>false, 'error'=>error.is_a?(Failure) ? error.message : '后端执行失败，请检查运行配置和文件权限', 'conflict'=>error.is_a?(Conflict)})
    exit 1
  end
end

OCMultiport.run if $PROGRAM_NAME == __FILE__
