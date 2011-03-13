#***********************************************************************************
#
# All code (C) Pete Warden, 2011
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
#***********************************************************************************

require 'rubygems' if RUBY_VERSION < '1.9'
require 'sinatra'
require 'json'
require 'net/geoip'
require '../geocoder/lib/geocoder/us/database'

# Some hackiness to include the library script, even if invoked from another directory
cwd = File.expand_path(File.dirname(__FILE__))
require File.join(cwd, 'geodict_lib')
require File.join(cwd, 'geodict_config')

enable :run

# Utility functions

# Pulls a request argument if it's been specified, otherwise uses the default
def get_or_default(hash, key, default)

  if hash.has_key?(key)
    hash[key]
  else
    default
  end
end

# Returns a JSON representation of the hash, optionally wrapped in a callback
def make_json(hash, callback = nil)
  result = ''
  if callback
    result += callback+'('
  end
  result += hash.to_json
  if callback
    result += ');'
  end
  
  return result
end

# Returns an error code and message, and then exits
def fatal_error(message, output_format = 'xml', code = 500, callback = nil)

  if output_format == 'xml'
    content = '<?xml version="1.0" encoding="utf-8"?><error>'+message+'</error>'
  elsif output_format == 'json'
    # A bit of a hack, but switch the code for JSONP requests, since otherwise
    # there's no way for the client Javascript code to know there was an error.
    if callback
      code = 200
    end
    content = make_json({ :error => message }, callback)
  else
    content = message
  end

  halt code, content

end

# Converts a Geodict symbol for a type of place into a Yahoo string
def convert_geodict_to_yahoo_type(geodict_type)
  if geodict_type == :COUNTRY
    'Country'
  elsif geodict_type == :REGION
    'Region'
  elsif geodict_type == :CITY
    'Town'
  else
    fatal_error('Internal error - bad Geodict place type "'+geodict_type+'"')
  end

end

# Emulates the interface to Yahoo's Placemaker API
# See http://developer.yahoo.com/geo/placemaker/guide/web-service.html for documentation
def placemaker_api_call(params)
  input_language = get_or_default(params, 'inputLanguage', 'en-US')
  output_type = get_or_default(params, 'outputType', 'xml')
  callback = get_or_default(params, 'callback', nil)
  document_content = get_or_default(params, 'documentContent', nil)
  document_title = get_or_default(params, 'documentTitle', nil)
  document_url = get_or_default(params, 'documentURL', nil)
  document_type = get_or_default(params, 'documentType', 'text/plain')
  auto_disambiguate = get_or_default(params, 'autoDisambiguate', true)
  focus_woeid = get_or_default(params, 'focusWoeId', nil)
  confidence = get_or_default(params, 'confidence', '8')
  character_limit = get_or_default(params, 'character_limit', nil)
  app_id = get_or_default(params, 'appid', nil)

  # Only a subset of Yahoo's functionality is supported, so check to make sure the
  # client isn't requesting anything we can't handle.
  if input_language != 'en-US'
    fatal_error('Unsupported inputLanguage: "'+input_language+'"', output_type, 500, callback)
  end

  if output_type != 'xml' and output_type != 'json'
    fatal_error('Unsupported outputType: "'+output_type+'"', output_type, 500, callback)
  end

  if !document_content and !document_url
    fatal_error('You must specify either a documentContent or a documentURL parameter', output_type, 500, callback)
  end

  if document_url
    fatal_error('The documentURL method of grabbing content is not yet supported', output_type, 500, callback)
  end

  if document_type != 'text/plain'
    fatal_error('Unsupported documentType: "'+document_type+'"', output_type, 500, callback)
  end

  # Start timing how long this all takes
  processing_start_time = Time.now

  # Grab the input content
  if document_type == 'text/plain'
    input_text = document_content
  end

  # Run the location extraction process
  locations = find_locations_in_text(input_text)
  
  puts locations.inspect

  # Calculate the elapsed time for processing
  processing_end_time = Time.now
  processing_duration = processing_end_time-processing_start_time

  # Make sure we return at least one location, even if it's bogus
  if locations.length == 0
    locations = [{:found_tokens=>[{
      :type => :COUNTRY,
      :lat => 0,
      :lon => 0,
      :start_index => 0,
      :end_index => 1,
      :code => 'NA',
      :matched_string => '?'
    }]}]
  end

  # Convert the raw locations into a form that works well with Yahoo's format
  yahoo_locations = []
  locations.each_with_index do |location_info, index|

    found_tokens = location_info[:found_tokens]

    match_start_index = found_tokens[0][:start_index]
    match_end_index = found_tokens[found_tokens.length-1][:end_index]
    matched_string = input_text[match_start_index..match_end_index]

    location = found_tokens[0]
    yahoo_locations.push({
      # We don't have the actual WOEID, so just create a locally-unique ID
      :woeid => index.to_s,
      :yahoo_type => convert_geodict_to_yahoo_type(location[:type]),
      :name => location[:matched_string],
      :lat => location[:lat].to_s,
      :lon => location[:lon].to_s,
      :start_index => location[:start_index].to_s,
      :end_index => location[:end_index].to_s,
      :matched_string => matched_string
    })
  end
  
  first_location = yahoo_locations[0]

  if output_type == 'xml'

    result = <<-XML
<?xml version="1.0" encoding="utf-8"?>
  <contentlocation
    xmlns:yahoo="http://www.yahooapis.com/v1/base.rng"
    xmlns:xml="http://www.w3.org/XML/1998/namespace"
    xmlns="http://wherein.yahooapis.com/v1/schema"
    xml:lang="en">
    XML
    
    result += '  <processingTime>'+processing_duration.to_s+'</processingTime>'+"\n"
    result += '  <version>Geodict build 000000</version>'+"\n"
    result += '  <documentLength>'+input_text.length.to_s+'</documentLength>'+"\n"
    
    result += '  <document>'+"\n"
        
    result += <<-XML
    <administrativeScope>
      <woeId>#{first_location[:woeid]}</woeId>
      <type>#{first_location[:yahoo_type]}</type>
      <name><![CDATA[#{first_location[:name]}]]></name>
      <centroid>
        <latitude>#{first_location[:lat]}</latitude>
        <longitude>#{first_location[:lon]}</longitude>
      </centroid>
    </administrativeScope>
    <geographicScope>
      <woeId>#{first_location[:woeid]}</woeId>
      <type>#{first_location[:yahoo_type]}</type>
      <name><![CDATA[#{first_location[:name]}]]></name>
      <centroid>
        <latitude>#{first_location[:lat]}</latitude>
        <longitude>#{first_location[:lon]}</longitude>
      </centroid>
    </geographicScope>
    <extents>
      <center>
        <latitude>#{first_location[:lat]}</latitude>
        <longitude>#{first_location[:lon]}</longitude>
      </center>
      <southWest>
        <latitude>#{first_location[:lat]}</latitude>
        <longitude>#{first_location[:lon]}</longitude>
      </southWest>
      <northEast>
        <latitude>#{first_location[:lat]}</latitude>
        <longitude>#{first_location[:lon]}</longitude>
      </northEast>
    </extents>
    XML
    
    yahoo_locations.each do |location|
      result += <<-XML
    <placeDetails>
      <place>
        <woeId>#{location[:woeid]}</woeId>
        <type>#{location[:yahoo_type]}</type>
        <name><![CDATA[#{location[:name]}]]></name>
        <centroid>
          <latitude>#{location[:lat]}</latitude>
          <longitude>#{location[:lon]}</longitude>
        </centroid>
      </place>
      <matchType>0</matchType>
      <weight>1</weight>
      <confidence>10</confidence>
    </placeDetails>
      XML
    end
    
    result += '    <referenceList>'+"\n"
    yahoo_locations.each do |location|
      result += <<-XML
      <reference>
        <woeIds>#{location[:woeid]}</woeIds>
        <start>#{location[:start_index]}</start>
        <end>#{location[:end_index]}</end>
        <isPlaintextMarker>1</isPlaintextMarker>
        <text><![CDATA[#{location[:matched_string]}]]></text>
        <type>plaintext</type>
        <xpath><![CDATA[]]></xpath>
      </reference>
      XML
    end

    result += '    </referenceList>'+"\n"

    result += <<-XML
  </document>
</contentlocation>
    XML
  
  elsif output_type == 'json'

    output_object = {
      'processingTime' => processing_duration.to_s,
      'version' => 'Geodict build 000000',
      'documentLength' => input_text.length.to_s,
      'document' => {
        'administrativeScope' => {
          'woeId' => first_location[:woeid],
          'type' => first_location[:yahoo_type],
          'name' => first_location[:name],
          'centroid' => {
            'latitude' => first_location[:lat],
            'longitude' => first_location[:lon]
          }
        },
        'geographicScope' => {
          'woeId' => first_location[:woeid],
          'type' => first_location[:yahoo_type],
          'name' => first_location[:name],
          'centroid' => {
            'latitude' => first_location[:lat],
            'longitude' => first_location[:lon]
          }
        },
        'extents' => {
          'center' => {
            'latitude' => first_location[:lat],
            'longitude' => first_location[:lon]
          },
          'southWest' => {
            'latitude' => first_location[:lat],
            'longitude' => first_location[:lon]
          },
          'northEast' => {
            'latitude' => first_location[:lat],
            'longitude' => first_location[:lon]
          }
        },
        'referenceList' => []
      }
    }
    
    doc = output_object['document']
    
    yahoo_locations.each_with_index do |location, index|
      
      doc[index] = { 'placeDetails' => {
        'placeId' => (index+1),
        'place' => {
          'woeId' => location[:woeid],
          'type' => location[:yahoo_type],
          'name' => location[:name],
          'centroid' => {
            'latitude' => location[:lat],
            'longitude' => location[:lon]
          }
        },
        'placeReferenceIds' => index,
        'matchType' => 0,
        'weight' => 1,
        'confidence' => 10
      }}
      
      doc['referenceList'].push({ 'reference' => {
        'woeIds' => location[:woeid],
        'placeReferenceId' => (index+1),
        'placeIds' => index,
        'start' => location[:start_index],
        'end' => location[:end_index],
        'isPlaintextMarker' => 1,
        'text' => location[:matched_string],
        'type' => 'plaintext',
        'xpath' => ''
      }})
      
    end
      
    puts output_object.inspect
      
    result = make_json(output_object, callback)
  
  end

  return result
end

# Takes an array of IP addresses as input, and looks up their locations using the
# free database from GeoMind
def ip2location(ips, callback=nil)

  geoip = Net::GeoIP.new(GeodictConfig::IP_MAPPING_DATABASE)

  output = {}
  ips.each do |ip|
    begin
      record = geoip[ip]
      info = {
        :country_code => record.country_code,
        :country_code3 => record.country_code3,
        :country_name => record.country_name,
        :region => record.region,
        :locality => record.city,
        :latitude => record.latitude,
        :longitude => record.longitude,
        :dma_code => record.dma_code,
        :area_code => record.area_code
      }
      begin
        info[:postal_code] = record.postal_code
      rescue ArgumentError
        info[:postal_code] = ''
      end
    rescue Net::GeoIP::RecordNotFoundError, ArgumentError
      info = nil
    end
    output[ip] = info
  end
  
  result = make_json(output, callback)
  
  return result

end

# Takes a possibly JSON-encoded or comma-separated string, and splits into IPs
def ips_list_from_string(ips_string)

  # Do a bit of trickery to handle both JSON-encoded and comma-separated lists of
  # IP addresses
  ips_string.gsub!(/["\[\]]/, '') #"

  ips_list = ips_string.split(',')
  
end

# Takes an array of postal addresses as input, and looks up their locations using
# data from the US census
def street2location(addresses, callback=nil)

  db = Geocoder::US::Database.new('../geocoderdata/geocoder.db', {:debug => false})

  output = {}
  addresses.each do |address|
    begin
      location = db.geocode(address, true)
      if location
        info = {
          :country_code => 'US',
          :country_code3 => 'USA',
          :country_name => 'United States',
          :region => location.state,
          :locality => location.city,
          :street_address => location.number+' '+location.street,
          :street_number => location.number,
          :street_name => location.street,
          :confidence => location.score,
          :fips_county => location.fips_county
        }
      else
        info = nil
      end
    rescue
      info = nil
    end
    output[address] = info
  end
  
  result = make_json(output, callback)
  
  return result

end

# Takes either a JSON-encoded string or single address, and produces a Ruby array
def addresses_list_from_string(addresses_string, callback=nil)

  if addresses_string == ''
    fatal_error('Empy string passed in to street2location', 
      'json', 500, callback)
  end
  
  # Do a bit of trickery to handle both JSON-encoded and single addresses
  first_character = addresses_string[0].chr
  if first_character == '['
    result = JSON.parse(addresses_string)
  else
    result = [addresses_string]
  end
  
  result
end

########################################
# Methods to directly serve up content #
########################################

# The main page.
get '/' do
  
  @headline = 'Welcome to the Geodict API Server'
  
  haml :welcome

end

get '/developerdocs' do
  
  @headline = 'Developer Documentation'
  
  haml :developerdocs

end

get '/about' do
  
  @headline = 'About'
  
  haml :about

end

########################################
# API entry points                     #
########################################

# The normal POST interface for Yahoo's Placemaker
post '/v1/document' do
  placemaker_api_call(params)
end

# Also support a non-standard GET version of the API for Javascript clients
get '/v1/document' do
  placemaker_api_call(params)
end

# The POST interface for the IP address to location lookup
post '/ip2location' do
  # Pull in the raw data in the body of the request
  ips_string = request.env['rack.input'].read
  
  if !ips_string
    fatal_error('You need to place the IP addresses as a comma-separated list inside the POST body', 
      'json', 500, nil)
  end
  ips_list = ips_list_from_string(ips_string)

  ip2location(ips_list)
end

# The GET interface for the IP address to location lookup
get '/ip2location/:ips' do

  callback = params[:callback]
  ips_string = params[:ips]
  if !ips_string
    fatal_error('You need to place the IP addresses as a comma-separated list as part of the URL', 
      'json', 500, callback)
  end

  ips_list = ips_list_from_string(ips_string)

  ip2location(ips_list, callback)
end

# The POST interface for the street address to location lookup
post '/street2location' do
  # Pull in the raw data in the body of the request
  addresses_string = request.env['rack.input'].read
  
  if !addresses_string
    fatal_error('You need to place the street addresses as a JSON-encoded array of strings inside the POST body', 
      'json', 500, nil)
  end
  addresses_list = addresses_list_from_string(addresses_string)

  street2location(addresses_list)
end

# The GET interface for the street address to location lookup
get '/street2location/:ips' do

  callback = params[:callback]
  addresses_string = params[:addresses]
  if !addresses_string
    fatal_error('You need to place the street addresses as a JSON-encoded array of strings as part of the URL', 
      'json', 500, callback)
  end

  addresses_list = ips_list_from_string(addresses_string, callback)

  street2location(addresses_list, callback)
end

