local boundary = require("boundary")
local timer = require("timer")
local http = require("http")
local json = require("json")
local dns = require("dns")

local authKey, param

local __pkg = "Boundary ActiveMQ Plugin"
local __ver = "Version 1.0"
local __tags = "lua,plugin,activemq"

-- base64
-- encoding username and password for basic auth
local function base64(data)
    local b='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    return ((data:gsub('.', function(x)
        local r,b='',x:byte()
        for i=8,1,-1 do r=r..(b%2^i-b%2^(i-1)>0 and '1' or '0') end
        return r
    end)..'0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
    if (#x < 6) then return '' end
        local c=0
        for i=1,6 do c=c+(x:sub(i,i)=='1' and 2^(6-i) or 0) end
        return b:sub(c+1,c+1)
    end)..({ '', '==', '=' })[#data%3+1])
end

-- poll
-- function to poll the server
local function poll()
    local destReqs = {}
    local destStats = {
        EnqueueCount = 0,
        DequeueCount = 0,
        InFlightCount = 0,
        DispatchCount = 0,
        ExpiredCount = 0,
        QueueSize = 0
    }
    local brokerStats

    local request = function(objectName, cb)
        http.request({
            host = param.activeMQHost,
            port = param.activeMQPort,
            headers = { Authorization = authKey },
            path = "/api/jolokia/read/" .. objectName
        }, function(res)
            local data = ""
            local result
            res:on("data", function (chunk)
                data = data .. chunk
                if pcall(function() result = json.parse(data) end) then
                    -- close connection if we have a valid json body
                    -- TODO: find a better way to close as there's no Content-length in response
                    res:emit("end")
                end
            end)
            res:on("end", function ()
                if result.status == 200 then
                    cb(result.value)
                else
                    error("Error returned from activemq server")
                end
            end)
        end):done()
    end

    local destination_request = function(obj)
        destReqs[obj] = obj
        request(obj, function(result)
            for k, v in pairs(destStats) do
                destStats[k] = v + result[k]
            end
            destReqs[obj] = nil
        end)
    end

    local output = function()
        for k, v in pairs(destReqs) do
            timer.setTimeout(1, output)   -- some requests not finished, come back in a ms
            return
        end
        -- all requests are done, output the stats
        local metrics = {}
        for i, v in ipairs({
            {"ACTIVEMQ_BROKER_TOTALS_QUEUES %d %s", #brokerStats.Queues},
            {"ACTIVEMQ_BROKER_TOTALS_TOPICS %d %s", #brokerStats.Topics},
            {"ACTIVEMQ_BROKER_TOTALS_PRODUCERS %d %s", brokerStats.TotalProducerCount},
            {"ACTIVEMQ_BROKER_TOTALS_CONSUMERS %d %s", brokerStats.TotalConsumerCount},
            {"ACTIVEMQ_BROKER_TOTALS_MESSAGES %d %s", brokerStats.TotalMessageCount},
            {"ACTIVEMQ_MESSAGE_STATS_ENQUEUE %d %s", destStats.EnqueueCount},
            {"ACTIVEMQ_MESSAGE_STATS_DEQUEUE %d %s", destStats.DequeueCount},
            {"ACTIVEMQ_MESSAGE_STATS_INFLIGHT %d %s", destStats.InFlightCount},
            {"ACTIVEMQ_MESSAGE_STATS_DISPATCH %d %s", destStats.DispatchCount},
            {"ACTIVEMQ_MESSAGE_STATS_EXPIRED %d %s", destStats.ExpiredCount},
            {"ACTIVEMQ_MESSAGE_STATS_QUEUE_SIZE %d %s", destStats.QueueSize},
            {"ACTIVEMQ_MEM_USED %d %s", brokerStats.MemoryPercentUsage},
            {"ACTIVEMQ_STORE_USED %d %s", brokerStats.StorePercentUsage}
        }) do
            table.insert(metrics, string.format(v[1], v[2], param.activeMQBroker))
        end
        print(table.concat(metrics, "\n"))
    end

    request("org.apache.activemq:type=Broker,brokerName=" .. param.activeMQBroker,
        function (result)
            brokerStats = result
            for i, v in ipairs(result.Topics) do
                destination_request(v.objectName)
            end
            for i, v in ipairs(result.Queues) do
                destination_request(v.objectName)
            end
            timer.setTimeout(100, output)
        end
    )
end

-- setup

-- set default parameters if not found in param.json
param = boundary.param or {}
param.pollInterval = param.pollInterval or 5000
param.activeMQHost = param.activeMQHost or "localhost"
param.activeMQBroker = param.activeMQBroker or "localhost"
param.activeMQPort = param.activeMQPort or 8161
param.activeMQUser = param.activeMQUser or "admin"
param.activeMQPass = param.activeMQPass or "admin"

-- create the basic auth key for the api http requests
authKey = "Basic " .. base64(param.activeMQUser .. ":" .. param.activeMQPass)

print("_bevent:"..__pkg..":"..__ver..":Up|t:info|tags:"..__tags)

poll()
timer.setInterval(param.pollInterval, poll)
