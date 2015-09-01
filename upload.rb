require 'dotenv'
Dotenv.load # load environment vars (CollectiveAccess auth credentials) from .env

require 'collectiveaccess'
require 'yaml'
require 'json'
require 'logger'
require 'net/scp'

#
# helper functions
#

def translate_locale(locale = 'de')
  case locale
    when 'en'
      'en_US'
    when 'fr'
      'fr_FR'
    when 'ar'
      'ar_MA'
    else
      'de_DE' # figure the first exhibit is in Germany, so have that be the default if something's off in the JSON
  end
end

#
# end helpers
#

# setup logging
logger = Logger.new(STDOUT)
logger.level = Logger::INFO

# load configuration
config = YAML.load_file(File.dirname(__FILE__) + File::SEPARATOR + 'config.yml')

# load directory contents
Dir.glob(config['local_directory'] + File::SEPARATOR + '*.json') do |item|
  logger.info "Started processing #{item}"

  json = JSON.parse(File.open(item, 'r').read)

  # skip files that have already been uploaded or are uploading right now
  if json['uploaded'] || json['isUploading']
    logger.info "Skipped #{item} because uploaded/isUploading is true"
    next
  end

  # let's save the uploaded state in the json file so that we don't process it again
  json['isUploading'] = true

  File.open(item,'w') do |f|
    f.write(JSON.pretty_generate(json))
  end

  media_file_name = File.basename(item, '.json') + '.mp4'
  media_file_path = config['local_directory'] + File::SEPARATOR + media_file_name

  raise 'video file for ' + item + ' is missing' unless File.exists?(media_file_path)

  # upload video file to alhalqa server
  Net::SCP.start(ENV['SSH_HOST'], ENV['SSH_USER'], keys: [ENV['SSH_PRIVATE_KEY']], port: ENV['SSH_PORT']) do |scp|
    logger.info 'SCP started for ' + media_file_name
    scp.upload! media_file_path, config['upload_directory']
  end
  logger.info 'SCP successful'

  # this is where the file is at on the remote server after the scp upload
  # note: directory contents should be nuked every once in a while
  remote_media_path = config['upload_directory'] + File::SEPARATOR + media_file_name

  # for testing:
  #remote_media_path = '/web/08-03-2015-12-53-12-recording.mp4'

  # if entity not found create new one using the name, phone# and email from JSON
  entity = CollectiveAccess.put protocol: 'https', hostname: config['hostname'], url_root: config['url_root'], table_name: 'ca_entities', endpoint: 'item',
                       request_body: {
                         intrinsic_fields: {
                           type_id: 'real_person',
                           access: json['may_publish_name'] ? 1 : 0
                         },
                         preferred_labels: [
                           {
                             displayname: json['name'],
                             locale: translate_locale(json['locale'])
                           }
                         ],
                         attributes: {
                           email: [
                             {
                               email: json['email']
                             }
                           ],
                           phone: [
                             {
                               phone: json['phone']
                             }
                           ]
                         }
                       }

  raise 'Creating the entity record seems to have failed ' + "#{entity}" unless entity['entity_id']

  # create new story record
  if json['story_title'] && (json['story_title'].length > 0)
    story = CollectiveAccess.put protocol: 'https', hostname: config['hostname'], url_root: config['url_root'], table_name: 'ca_occurrences', endpoint: 'item',
                               request_body: {
                                 intrinsic_fields: {
                                   type_id: 'story',
                                 },
                                 preferred_labels: [
                                   {
                                     name: json['story_title'],
                                     locale: translate_locale(json['locale'])
                                   }
                                 ],
                                 attributes: {
                                   long_description: [
                                     {
                                       long_description: json['story_description'],
                                       locale: translate_locale(json['locale'])
                                     }
                                   ],
                                 }
                               }

    raise 'Creating the story record seems to have failed' unless story['occurrence_id']
    logger.info "Created story with id #{story['occurrence_id']}"
  else
    story = false
  end

  # create new object with user title and description, and relate to everything
  object_body = {
    intrinsic_fields: {
      type_id: 'video',
    },
    preferred_labels: [
      {
        name: json['story_title'],
        locale: translate_locale(json['locale'])
      }
    ],
    attributes: {
      short_description: [
        {
          short_description: json['story_description'],
          locale: translate_locale(json['locale'])
        }
      ],
    },
    related: {
      ca_entities: [
        {
          entity_id: entity['entity_id'],
          type_id: 'created'
        }
      ],
      # collection for all storytelling records
      ca_collections: [
        {
          collection_id: config['collection_id'],
          type_id: 'part_of'
        }
      ],
      # set for storytelling records from current exhibit 'stage'
      # (starting in Berlin-Dahlem)
      ca_sets: [
        {
          set_id: config['set_id']
          # note: no rel type id
        }
      ]
    },
    representations: [
      {
        media: remote_media_path,
        type: 'front',
        access: 0,
        status: 4,
        locale: 'en_US',
        values: {
          name: 'Automatically uploaded by Erzählbox'
        }
      }
    ]
  }

  if story && story['occurrence_id']
    object_body[:related][:ca_occurrences] = [
      {
        occurrence_id: story['occurrence_id'],
        type_id: 'record'
      }
    ]
  end

  obj = CollectiveAccess.put protocol: 'https', hostname: config['hostname'], url_root: config['url_root'], table_name: 'ca_objects', endpoint: 'item',
                             request_body: object_body

  raise 'Creating the object seems to have failed' unless obj['object_id']
  logger.info "Created object with id #{obj['object_id']}"

  # let's save the uploaded state in the json file so that we don't process it again
  json['uploaded'] = true
  json['isUploading'] = false

  File.open(item,'w') do |f|
    f.write(JSON.pretty_generate(json))
  end

end
