-- Copyright 2015 Boundary, Inc.
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--    http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

local framework = require('framework')
local Plugin = framework.Plugin
local notEmpty = framework.string.notEmpty
local WebRequestDataSource = framework.WebRequestDataSource
local hasAny = framework.table.hasAny
local auth = framework.util.auth
local clone = framework.table.clone
local table = require('table')
local parseJson = framework.util.parseJson
local get = framework.table.get

local params = framework.params

params.pollInterval = notEmpty(params.pollInterval, 5000)
params.host = notEmpty(params.host, "localhost")
params.broker_name = notEmpty(params.broker_name, "localhost")
params.port = notEmpty(params.port, 8161)
params.source = notEmpty(params.sourceName, params.broker_name)

local options = {}
options.host = params.host
options.port = params.port
options.auth = auth(params.username, params.password)
options.path = "/api/jolokia/read/org.apache.activemq:type=Broker,brokerName=" .. params.broker_name
options.wait_for_end = true

local function childDataSource(object)
  local opts = clone(options)
  opts.path = "/api/jolokia/read/" .. object
  opts.meta = object
  return WebRequestDataSource:new(opts)
end

local pending_requests = {}
local plugin
local ds = WebRequestDataSource:new(options)
ds:chain(function (context, callback, data)
  local success, parsed = parseJson(data)
  if not success then
    context:emit('error', 'Can not parse metrics. Verify configuration parameters.')
    return
  end
  parsed = get('value', parsed)
  local metrics = {
    ['ACTIVEMQ_BROKER_TOTALS_QUEUES'] = parsed.Queues and #parsed.Queues,
    ['ACTIVEMQ_BROKER_TOTALS_TOPICS'] = parsed.Topics and #parsed.Topics,
    ['ACTIVEMQ_BROKER_TOTALS_PRODUCERS'] = parsed.TotalProducerCount,
    ['ACTIVEMQ_BROKER_TOTALS_CONSUMERS'] = parsed.TotalConsumerCount,
    ['ACTIVEMQ_BROKER_TOTALS_MESSAGES'] = parsed.TotalMessageCount,
    ['ACTIVEMQ_MEM_USED'] = parsed.MemoryPercentUsage,
    ['ACTIVEMQ_STORE_USED'] = parsed.StorePercentUsage,
  }
  plugin:report(metrics)

  local data_sources = {}
  for _, v in ipairs(parsed.Topics) do
    local child_ds = childDataSource(v.objectName)
    child_ds:propagate('error', context)
    table.insert(data_sources, child_ds)
    pending_requests[v.objectName] = true
  end
  for _, v in ipairs(parsed.Queues) do
    local child_ds = childDataSource(v.objectName)
    child_ds:propagate('error', context)
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

plugin = Plugin:new(params, ds)
function plugin:onParseValues(data, extra)
  local success, parsed = parseJson(data)
  if not success then
    self:error('Can not parse metrics. Verify configuration parameters.')
    return
  end
  parsed = get('value', parsed)
  local metrics = {}

  -- Sum up all the stats
  for k, v in pairs(stats_total) do
    stats_total[k] = v + tonumber(parsed[k]) or 0
  end
  pending_requests[extra.info] = nil
  if not hasAny(pending_requests) then
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

