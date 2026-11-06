-- OC_MULTIPORT_BACKEND_V7
module("luci.controller.openclash_proxy_multiport", package.seeall)

function index()
    local page = entry({"admin", "services", "openclash_multiport"}, call("action_state"))
    page.leaf = false
    page.acl_depends = {"luci-app-openclash"}
    entry({"admin", "services", "openclash_multiport", "state"}, call("action_state")).leaf = true
    entry({"admin", "services", "openclash_multiport", "apply"}, post("action_apply")).leaf = true
    entry({"admin", "services", "openclash_multiport", "delay"}, post("action_delay")).leaf = true
    entry({"admin", "services", "openclash_multiport", "nodes"}, call("action_nodes")).leaf = true
    entry({"admin", "services", "openclash_multiport", "node_delay"}, post("action_node_delay")).leaf = true
    entry({"admin", "services", "openclash_multiport", "node_ip"}, post("action_node_ip")).leaf = true
end

local function reply(code, value)
    local http = require "luci.http"
    http.status(code)
    http.header("Cache-Control", "no-store")
    http.prepare_content("application/json")
    http.write_json(value)
end

local function worker(command, payload)
    local fs = require "nixio.fs"
    local util = require "luci.util"
    local json = require "luci.jsonc"
    local sys = require "luci.sys"
    if not fs.access("/usr/share/openclash/openclash_proxy_multiport.rb", "r") then
        return reply(500, {ok=false, error="缺少 /usr/share/openclash/openclash_proxy_multiport.rb，请检查文件位置"})
    end
    local path
    if payload then
        -- nixio.mkstemp returns ONLY an already-unlinked handle, not a path.
        -- Ruby needs a named file: create it exclusively with mode 600 instead.
        local token = sys.uniqueid(16)
        if type(token) ~= "string" or #token ~= 32 or not token:match("^%x+$") then
            return reply(500, {ok=false, error="无法生成请求文件名，未应用配置"})
        end
        path = "/tmp/oc-multiport-request-" .. token
        local nixio = require "nixio"
        local fd = nixio.open(path, nixio.open_flags("wronly", "creat", "excl"), "rw-------")
        if not fd then return reply(500, {ok=false, error="无法创建请求文件，未应用配置"}) end
        local written = fd:writeall(payload)
        fd:close()
        if not written or (type(written) == "number" and written ~= #payload) then
            fs.unlink(path)
            return reply(500, {ok=false, error="无法完整写入请求文件，未应用配置"})
        end
    end
    -- Only fixed command names and a server-generated path reach the shell.
    local cmd = "ruby -E UTF-8 /usr/share/openclash/openclash_proxy_multiport.rb " .. command
    if path then cmd = cmd .. " " .. util.shellquote(path) end
    local ran, output = pcall(sys.exec, cmd .. " 2>/dev/null")
    if path then fs.unlink(path) end
    if not ran then
        return reply(500, {ok=false, error="无法执行代理配置后端，请检查系统运行状态"})
    end
    local result = json.parse(output or "")
    if type(result) ~= "table" then
        return reply(500, {ok=false, error="后端无法启动，请检查 OpenClash 自身的 Ruby/YAML，以及 openclash_proxy_multiport.rb 的文件内容"})
    end
    -- Validate for routing/status, but forward the worker's JSON unchanged.
    -- Re-encoding through a Lua table can turn an empty [] into {}.
    local http = require "luci.http"
    http.status(result.ok and 200 or (result.conflict and 409 or 400))
    http.header("Cache-Control", "no-store")
    http.prepare_content("application/json")
    http.write(output)
end

function action_state()
    worker("state")
end

function action_apply()
    local payload = require("luci.http").formvalue("payload")
    if type(payload) ~= "string" or #payload > 131072 then
        return reply(400, {ok=false, error="配置数据为空或过大"})
    end
    worker("apply", payload)
end

function action_delay()
    local payload = require("luci.http").formvalue("payload")
    if type(payload) ~= "string" or #payload > 4096 then
        return reply(400, {ok=false, error="延迟检测参数为空或过大"})
    end
    worker("delay", payload)
end

function action_nodes()
    worker("nodes")
end

local function node_request(command)
    local payload = require("luci.http").formvalue("payload")
    if type(payload) ~= "string" or #payload > 4096 then
        return reply(400, {ok=false, error="节点参数为空或过大"})
    end
    worker(command, payload)
end

function action_node_delay()
    node_request("node_delay")
end

function action_node_ip()
    node_request("node_ip")
end
