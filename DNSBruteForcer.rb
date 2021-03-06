require 'net/dns'
require 'open-uri'
require 'json'
require 'whois'

class DNSBruteForcer
  
  attr_accessor :dictionary, :domain, :geodetails, :threads, :whois
  attr_reader :dnsips, :foundhosts
  
  
  ###################
  
  def initialize()
    @dnsserver = Net::DNS::Resolver.new(:searchlist=>[],:domain=>[],:udp_timeout=>15)
    @dnsips = @dnsserver.nameservers
    @dictionary = nil
    @domain = nil
    @threads = 5
    @nsrecords = [] # each record will have the form {:hostname => name, :ip => ip, :type => CNAME/A}
    @geodetails = false
    @whois = false
    @foundhosts = []
    @w = Whois::Client.new
  end
  
  ###################
  
  def setNameServers(nameservers)
    @dnsserver = Net::DNS::Resolver.new(:nameservers => nameservers, :searchlist=>[],:domain=>[],:udp_timeout=>15)
    @dnsips = @dnsserver.nameservers
  end
  
  ###################
  
  def getWhoisInfo(host)
    begin
      r = @w.lookup(host)
      return r.to_s
    rescue Exception => e
      $stderr.puts "There was an error requesting whois info for #{host}"
      return ""
    end
  end
  
  ###################
  
  def getAuthDNSServers(domain)
    soaips = []
    begin
      authDNSs = @dnsserver.query(domain,Net::DNS::SOA)
      authDNSs.answer.each{|record|
        # Get the IP of this authdns and set it as our new DNS resolver
        if record.class == Net::DNS::RR::SOA
          soadns = record.mname
          # Get the IP of the SOA mname and set it as our new dns resolver
          @dnsserver.query(soadns,Net::DNS::A).answer.each { |arecord|
            soaips << arecord.address.to_s
          }
          return soaips
        else # Is not a SOA response (What could it be?)
          return nil
        end
      }
    rescue Net::DNS::Resolver::NoResponseError => terror
      puts "Error: #{terror.message}"
      return nil
    end
    return nil
  end
  
  ###################
  
  def getAllDNSServer(domain)
    dnsips = []
    begin
      dnss = @dnsserver.query(domain,Net::DNS::NS)
      dnss.answer.each{|record|
        # Get the IP of this authdns and set it as our new DNS resolver
        if record.class == Net::DNS::RR::NS
          dns = record.nsdname
          # Get the IP of the SOA mname and set it as our new dns resolver
          @dnsserver.query(dns,Net::DNS::A).answer.each { |arecord|
            dnsips << arecord.address.to_s
          }
        end
      }
      return dnsips
    rescue Net::DNS::Resolver::NoResponseError => terror
      puts "Error: #{terror.message}"
      return nil
    end
    return nil
  end
  
  ###################
  
  def getAllSOAServer(domain)
    soaips = []
    begin
      dnss = @dnsserver.query(domain,Net::DNS::SOA)
      dnss.answer.each{|record|
        # Get the IP of this authdns and set it as our new DNS resolver
        if record.class == Net::DNS::RR::SOA
          soaname = record.mname
          # Get the IP of the SOA mname and set it as our new dns resolver
          soasearchresponse = @dnsserver.query(soaname,Net::DNS::A)
          soasearchresponse.answer.each { |arecord|
            soaips << arecord.address.to_s
          }
          
          # For emergencies when the soa IP is not found we'll ask Google DNS
          if soaips.size == 0
            googledns = Net::DNS::Resolver.new(:nameservers => ["8.8.8.8"], :searchlist=>[],:domain=>[],:udp_timeout=>15)
            soasearchresponse = googledns.query(soaname,Net::DNS::A)
            soasearchresponse.answer.each { |arecord|
              soaips << arecord.address.to_s
            }
          end
        end
      }
      return soaips
    rescue Net::DNS::Resolver::NoResponseError => terror
      puts "Error: #{terror.message}"
      return nil
    end
    return nil
  end
  
  ###################
  
  def transferZone(domain)
    # Trying transfer zone for all NS of the domain
    zone = {
      :a => [],
      :ns => [],
      :cname => [],
      :soa => [],
      :ptr => [],
      :mx => [],
      :txt => [],
      :others => []
      }
    nsservers = self.getAllDNSServer(domain)
    if nsservers.nil?
      nsservers.each{|dnsip|
        domain_dns = Net::DNS::Resolver.new(:nameservers => dnsip, :searchlist=>[],:domain=>[],:udp_timeout=>15)
        transferresponse = domain_dns.axfr(domain)
        if transferresponse.header.rCode == Net::DNS::Header::RCode::NOERROR
          # Zone transfer was possible!
          transferresponse.answer.each{ |record|
            case record.class 
            when Net::DNS::RR::A
              zone[:a] << record
            when Net::DNS::RR::NS
              zone[:ns] << record
            when Net::DNS::RR::CNAME
              zone[:cname] << record
            when Net::DNS::RR::SOA
              zone[:soa] << record
            when Net::DNS::RR::PTR
              zone[:ptr] << record
            when Net::DNS::RR::MX
              zone[:mx] << record
            when Net::DNS::RR::TXT
              zone[:txt] << record
            else
              zone[:others] << record
            end
          }
          return zone
        else
          # Zone transfer was refused or any other error
          return nil
        end
      }
    else
      return nil
    end
  end
  
  ###################
  
  def getGeoDetails(ip)
    # If this is an IP checkit
    if /\A(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\Z/.match(ip.to_s)
      # Check if we already have this geographic information in our results
      @foundhosts.each{|h|
        if h[:ip].to_s == ip.to_s and !h[:geo].nil?
          puts "Geographic data of '#{ip}' has been previously requested to freegeoip.net. Returning local geo data."
          return h[:geo]
        end
      }
      # If this IP was not already requested, request to internet server 
      response = open("http://freegeoip.net/json/#{ip.to_s}")
      if !response.nil?
        geojson = response.readlines()
        j = JSON.parse(geojson[0])
        return j
      end
    end
    
    return nil
  end
  
  ###################
  
  def splitDictionary()
    nlines = %x(wc -l < #{@dictionary}).chomp.to_i
    words_for_threads = []
    
    File.open(@dictionary,"r").each.with_index {|subdomain,i|
      if words_for_threads[i.to_i%@threads.to_i].nil?
        words_for_threads[i.to_i%@threads.to_i] = []
      end
      words_for_threads[i%@threads.to_i] << subdomain 
    }
    
    return words_for_threads
  end
  
  ###################
  
  def bruteforceSubdomainsWithDNS(dns,domain)
    foundhosts = []
    geo = nil
    targetdns = Net::DNS::Resolver.new(:nameservers => dns, :searchlist=>[],:domain=>[],:udp_timeout=>15)
    
    # Split the dictionary in parts for the threads
    words_for_threads = splitDictionary()
    words_for_threads.each{|words|
      t = Thread.new {
        # each thread ask for a subset of the dictionary
        words.each { |subdomain|
          targeth = "#{subdomain.chomp}.#{domain}"
          begin 
            response = targetdns.query(targeth)
            # Type of the response is tp.answer[0].class
            # Address of the response is  tp.answer[0].address
            # Hostname tp.answer[0].name
            if response.header.rCode.type == "NoError"
              response.answer.each {|record|
                whois = ""
                addr = ""
                if record.type == "A"        
                  addr = record.address
                else
                  addr = record.cname
                end
                
                if (@whois)
                  puts "Retrieving whois information of '#{targeth}'"
                  whois = getWhoisInfo(targeth)
                end      
                if (@geodetails)
                  puts "Retrieving geographic information of '#{addr}'"
                  geo = getGeoDetails(addr)
                end    
                
                @foundhosts << {:name => targeth, :ip => addr, :type => record.type, :geo => geo, :whois => whois}
              }
            end
          rescue Net::DNS::Resolver::NoResponseError
            $stderr.puts "DNS server '#{dns}' did not respond to our query..."
          end
        }        
      }
      t.abort_on_exception = true #¿?
      t.join
    }
    return @foundhosts
  end
  
  ###################
  
  def bruteforceSubdomains(domain,alldns=false)
    @foundhosts = []
    
    if @dictionary.nil?
      return nil
    else
      nsservers = self.getAllDNSServer(domain)
      if !nsservers.nil? and nsservers.size > 0
        if alldns
          nsservers.each{|dnsip|
            bruteforceSubdomainsWithDNS(dnsip,domain) # .each {|record| @foundhosts << record }
          }
        else # Ask only to the first DNS
          dnsip = nsservers[0]
          # @foundhosts = 
          bruteforceSubdomainsWithDNS(dnsip,domain)
        end
      else
        # We could not find nameservers for this domain
        # This is probably a shared hosting and pointing to a SOA.
        # Just ask the SOA
        soaserver = getAllSOAServer(domain)
        if !soaserver.nil? and soaserver.size > 0
          if alldns
            soaserver.each{|soaip|
              bruteforceSubdomainsWithDNS(soaip,domain) # .each { |record| @foundhosts << record }
            }
          else # Ask only to the first DNS
            soaip = soaserver[0]
            # @foundhosts = 
            bruteforceSubdomainsWithDNS(soaip,domain)
          end
        else
          return nil          
        end
      end
    end
    
    return @foundhosts
  end
  
end