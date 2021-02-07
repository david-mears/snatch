# frozen_string_literal: true

require './app'
require './middlewares/snatch_backend'

use Snatch::SnatchBackend

run Snatch::App
