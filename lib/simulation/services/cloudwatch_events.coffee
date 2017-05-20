BaseService = require '../base_service'

class CloudWatchEvents extends BaseService

  paths: [
    'AWS:CloudWatchEvents'
  ]

  setup: (config, opts, callback) ->
    @port = config.port || 21321
    super arguments...

module.exports = CloudWatchEvents