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

  # upload video file to alhalqa server
  Net::SCP.start(ENV['SSH_HOST'], ENV['SSH_USER'], keys: [ENV['SSH_PRIVATE_KEY']], port: ENV['SSH_PORT']) do |scp|
    puts 'SCP copy started for ' + json['videofile']
    scp.upload!(json['videofile'], config['upload_directory'])
  end

  #remote_media_path = config['upload_directory'] + File::SEPARATOR + File.basename(json['videofile'])
  remote_media_path = '/tmp/07-24-2015-14-24-12-recording.mp4'

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
  rep_id = rep['representation_id']
  raise 'Representation upload seems to have failed' unless rep_id

  # create new object
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
                                     representation_id: rep_id
                                   }
                                 ]
                               }
                             }
  puts obj.inspect
end
