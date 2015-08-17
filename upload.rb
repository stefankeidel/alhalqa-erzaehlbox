require 'dotenv'
Dotenv.load # load environment vars (CollectiveAccess auth credentials) from .env

require 'collectiveaccess'
require 'yaml'
require 'json'
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

# load configuration
config = YAML.load_file(File.dirname(__FILE__) + File::SEPARATOR + 'config.yml')

# load directory contents
Dir.glob(config['local_directory'] + File::SEPARATOR + '*.json') do |item|
  json = JSON.parse(File.open(item, 'r').read)

  # skip files that have already been uploaded
  next if json['uploaded']

  media_file_name = File.basename(item, '.json') + '.mp4'
  media_file_path = config['local_directory'] + File::SEPARATOR + media_file_name

  raise 'video file for ' + item + ' is missing' unless File.exists?(media_file_path)

  # upload video file to alhalqa server
  Net::SCP.start(ENV['SSH_HOST'], ENV['SSH_USER'], keys: [ENV['SSH_PRIVATE_KEY']], port: ENV['SSH_PORT']) do |scp|
    puts 'SCP copy started for ' + media_file_name
    scp.upload! media_file_path, config['upload_directory']
  end

  # this is where the file is at on the remote server after the scp upload
  # note: directory contents should be nuked every once in a while
  remote_media_path = config['upload_directory'] + File::SEPARATOR + media_file_name

  # for testing:
  #remote_media_path = '/web/08-03-2015-12-53-12-recording.mp4'

  # try to find creator/person
  search_result = CollectiveAccess.get hostname: config['hostname'], url_root: config['url_root'], table_name: 'ca_entities', endpoint: 'find',
                                get_params: {
                                  q: 'ca_entity_labels.displayname:"' + json['name'] + '"', noCache: 1
                                }

  if search_result['results'] && search_result['results'].first()['id']
    # if we found something, use that entity to relate to the newly created object
    entity_id = search_result['results'].first()['id']
  else
    # if entity not found create new one using the name, phone# and email from JSON
    ent = CollectiveAccess.put hostname: config['hostname'], url_root: config['url_root'], table_name: 'ca_entities', endpoint: 'item',
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

    if ent['entity_id']
      entity_id = ent['entity_id']
    else
      raise "couldnt create entity. returned json was #{ent}"
    end

  end

  raise 'couldnt figure out which entity to use' unless entity_id

  # create new object representation
  rep = CollectiveAccess.put hostname: config['hostname'], url_root: config['url_root'], table_name: 'ca_object_representations', endpoint: 'item',
                           request_body: {
                             intrinsic_fields: {
                               type_id: 'front',
                               media: remote_media_path
                             },
                             preferred_labels: [
                               {
                                 # nobody should ever see this, but it helps identify
                                 # records uploaded this script later
                                 name: 'Automatically uploaded by Erzählbox',
                                 locale: 'en_US'
                               }
                             ]
                           }

  raise "Representation upload seems to have failed. JSON was: #{rep}" unless rep['representation_id']

  # create new story record
  story = CollectiveAccess.put hostname: config['hostname'], url_root: config['url_root'], table_name: 'ca_occurrences', endpoint: 'item',
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

  # create new object with user title and description, and relate to everything
  obj = CollectiveAccess.put hostname: config['hostname'], url_root: config['url_root'], table_name: 'ca_objects', endpoint: 'item',
                             request_body: {
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
                                 ca_object_representations: [
                                   {
                                     representation_id: rep['representation_id']
                                     # note: no rel type id
                                   }
                                 ],
                                 ca_entities: [
                                   {
                                     entity_id: entity_id,
                                     type_id: 'created'
                                   }
                                 ],
                                 ca_occurrences: [
                                   {
                                     occurrence_id: story['occurrence_id'],
                                     type_id: 'record'
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
                               }
                             }

  raise 'Creating the object seems to have failed' unless obj['object_id']

  # let's save the uploaded state in the json file so that we don't process it again
  json['uploaded'] = true

  File.open(item,'w') do |f|
    f.write(JSON.pretty_generate(json))
  end
end
