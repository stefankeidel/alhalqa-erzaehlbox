require 'dotenv'
Dotenv.load # load environment vars (CollectiveAccess auth credentials) from .env

require 'collectiveaccess'
require 'yaml'
require 'json'
require 'net/scp'

# load configuration
config = YAML.load_file(File.dirname(__FILE__) + File::SEPARATOR + 'config.yml')

# load directory contents
Dir.glob(config['local_directory'] + File::SEPARATOR + '*.json') do |item|
  json = JSON.parse(File.open(item, 'r').read)
  media_file_name = File.basename(item, '.json') + '.mp4'
  media_file_path = config['local_directory'] + File::SEPARATOR + media_file_name

  raise 'video file for ' + item + ' is missing' unless File.exists?(media_file_path)

  # upload video file to alhalqa server
  Net::SCP.start(ENV['SSH_HOST'], ENV['SSH_USER'], keys: [ENV['SSH_PRIVATE_KEY']], port: ENV['SSH_PORT']) do |scp|
    puts 'SCP copy started for ' + media_file_name
    scp.upload!(media_file_path, config['upload_directory'])
  end

  remote_media_path = config['upload_directory'] + File::SEPARATOR + media_file_name
  #remote_media_path = '/Users/stefan/07-24-2015-14-24-12-recording.mp4'

  # create new object representation
  rep = CollectiveAccess.put hostname: config['hostname'], table_name: 'ca_object_representations', endpoint: 'item',
                           request_body: {
                             intrinsic_fields: {
                               type_id: 'front',
                               media: remote_media_path
                             },
                             preferred_labels: [
                               {
                                 name: 'Automatically uploaded by Erzählbox',
                                 locale: 'en_US'
                               }
                             ]
                           }

  raise 'Representation upload seems to have failed' unless rep['representation_id']

  # create new object
  # @todo actually catalog relevant info from json
  obj = CollectiveAccess.put hostname: config['hostname'], table_name: 'ca_objects', endpoint: 'item',
                             request_body: {
                               intrinsic_fields: {
                                 type_id: 'photo',
                                 idno: 'test'
                               },
                               preferred_labels: [
                                 {
                                   name: 'Testobjekt uploaded by Erzählbox',
                                   locale: 'en_US'
                                 }
                               ],
                               related: {
                                 ca_object_representations: [
                                   {
                                     representation_id: rep['representation_id']
                                   }
                                 ]
                               }
                             }
  raise 'Creating the object seems to have failed' unless obj['object_id']

  # move json and mp4 out of the spooling dir
  File.rename media_file_path, config['finished_directory'] + File::SEPARATOR + media_file_name
  File.rename item, config['finished_directory'] + File::SEPARATOR + File.basename(item)
end
