local framework = require('framework')
local json = require('json')
local Plugin = framework.Plugin
local notEmpty = framework.string.notEmpty
local WebRequestDataSource = framework.WebRequestDataSource 
local auth = framework.util.auth
local clone = framework.table.clone
local table = require('table')

local params = framework.params
params.name = "Boundary ActiveMQ Plugin"
params.version = 2.0
params.tags = "lua,plugin,activemq"

params.pollInterval = notEmpty(params.pollInterval, 5000)
params.activeMQHost = notEmpty(params.activeMQHost, "localhost")
params.activeMQBroker = notEmpty(params.activeMQBroker, "localhost")
params.activeMQPort = notEmpty(params.activeMQPort, 8161)
params.activeMQUser = notEmpty(params.activeMQUser, "admin")
params.activeMQPass = notEmpty(params.activeMQPass, "admin")
params.source = params.activeMQBroker

local options = {}
options.host = params.activeMQHost
options.port = params.activeMQPort
options.auth = auth(params.activeMQUser, params.activeMQPass) 
options.path = "/api/jolokia/read/org.apache.activemq:type=Broker,brokerName=" .. params.activeMQBroker
options.wait_for_end = true -- Please look at how it behaves with activemq

local pending_requests = {}
local plugin
local ds = WebRequestDataSource:new(options)
ds:chain(function (context, callback, data)
  local parsed = json.parse(data).value
  -- Output broker metrics
  local metrics = {
    ['ACTIVEMQ_BROKER_TOTALS_QUEUES'] = #parsed.Queues,
    ['ACTIVEMQ_BROKER_TOTALS_TOPICS'] = #parsed.Topics,
    ['ACTIVEMQ_BROKER_TOTALS_PRODUCERS'] = parsed.TotalProducerCount,
    ['ACTIVEMQ_BROKER_TOTALS_CONSUMERS'] = parsed.TotalConsumerCount,
    ['ACTIVEMQ_BROKER_TOTALS_MESSAGES'] = parsed.TotalMessageCount,
    ['ACTIVEMQ_MEM_USED'] = parsed.MemoryPercentUsage,
    ['ACTIVEMQ_STORE_USED'] = parsed.StorePercentUsage,
  }
  plugin:report(metrics)

  -- Generate child requests
  local data_sources = {}
  for _, v in ipairs(parsed.Topics) do
    local opts = clone(options)
    opts.path = "/api/jolokia/read/" .. v.objectName
    opts.info = v.objectName
    local child_ds = WebRequestDataSource:new(opts)
    child_ds:propagte('error', context)
    table.insert(data_sources, child_ds)
    pending_requests[v.objectName] = true
  end
  for _, v in ipairs(parsed.Queues) do
    local opts = clone(options)
    opts.path = "/api/jolokia/read/" .. v.objectName
    opts.info = v.objectName
    local child_ds = WebRequestDataSource:new(opts)
    child_ds:propagte('error', context)
    table.insert(data_sources, child_ds)
    pending_requests[v.objectName] = true
  end
  return data_sources
end)

local stats_total_tmpl = {
  EnqueueCount = 0,
  DequeueCount = 0,
  InFlightCount = 0,
  DispatchCount = 0,
  ExpiredCount = 0,
  QueueSize = 0
}

local stats_total = clone(stats_total_tmpl)

local function arePendingRequests() 
  -- If has any key, then there are pending requests.
  for k, v in pairs(pending_requests) do
      return true 
  end

  return false 
end

plugin = Plugin:new(params, ds)
function plugin:onParseValues(data, extra)
  local parsed = json.parse(data).value
  local metrics = {}

  -- Sum up all the stats
  for k, v in pairs(stats_total) do
    stats_total[k] = v + tonumber(parsed[k]) or 0
  end
  pending_requests[extra.info] = nil
  if not arePendingRequests() then
  -- all requests are done, output the stats
    metrics = {
      ['ACTIVEMQ_MESSAGE_STATS_ENQUEUE'] = stats_total.EnqueueCount,
      ['ACTIVEMQ_MESSAGE_STATS_DEQUEUE'] = stats_total.DequeueCount,
      ['ACTIVEMQ_MESSAGE_STATS_INFLIGHT'] = stats_total.InFlightCount,
      ['ACTIVEMQ_MESSAGE_STATS_DISPATCH'] = stats_total.DispatchCount,
      ['ACTIVEMQ_MESSAGE_STATS_EXPIRED'] = stats_total.ExpiredCount,
      ['ACTIVEMQ_MESSAGE_STATS_QUEUE_SIZE'] = stats_total.QueueSize
    }
    stats_total = clone(stats_total_tmpl) 
  end

  return metrics
end

plugin:run()
