require 'em_test_helper'
require 'tempfile'

if EM.ssl?
  class TestSslVerify < Test::Unit::TestCase
    attr_writer :client_handshake_completed
    attr_writer :server_handshake_completed
    attr_writer :cert_from_server

    def setup
      @dir = File.dirname(File.expand_path(__FILE__)) + '/'
      @cert_from_file = File.read(@dir+'client.crt')
      @client_handshake_completed = false
      @server_handshake_completed = false
    end

    # create a TLS client module that records (in this test)
    # whether the handshake was completed
    def client
      test = self
      tls_options = { 
        :private_key_file => @dir+'client.key', 
        :cert_chain_file => @dir+'client.crt'
      }
      @client_handshake_completed = false
      Module.new do
        define_method :connection_completed do
          start_tls(tls_options)
        end
        define_method :ssl_handshake_completed do
          test.client_handshake_completed = true
          close_connection
        end
        define_method :unbind do
          EM.stop_event_loop
        end
      end
    end

    # create a TLS server module that records (in this test) 
    # whether the handshake was completed, 
    # and defers to the caller for ssl_verify_peer
    def server(tls_options, &ssl_verify_peer)
      test = self
      Module.new do
        define_method :post_init do
          start_tls(tls_options)
        end
        if ssl_verify_peer
          define_method :ssl_verify_peer, &ssl_verify_peer
        end
        define_method :ssl_handshake_completed do
          test.server_handshake_completed = true
        end
      end
    end
    
    # the cert that ssl_verify_peer gets should be the same one
    # that the client uses
    def test_cert_passthrough
      test = self
      EM.run do
        EM.start_server("127.0.0.1", 16784, server(:verify_peer => true) { |cert|
          test.cert_from_server = cert
          true
        })
        EM.connect("127.0.0.1", 16784, client).instance_variable_get("@signature")
      end

      assert_equal(@cert_from_file, @cert_from_server)
    end

    # accepting all certs should complete the handshake
    def test_accept_server
      EM.run do
        EM.start_server("127.0.0.1", 16784, server(:verify_peer => true) { |cert|
          true
        })
        EM.connect("127.0.0.1", 16784, client).instance_variable_get("@signature")
      end

      assert(@client_handshake_completed)
      assert(@server_handshake_completed)
    end

    # denying all certs should never complete the handshake
    def test_deny_server
      EM.run do
        EM.start_server("127.0.0.1", 16784, server(:verify_peer => true) { |cert|
          # Do not accept the peer. This should now cause the connection to
          # shut down without the SSL handshake being completed.
          false
        })
        EM.connect("127.0.0.1", 16784, client)
      end

      assert(!@client_handshake_completed)
      assert(!@server_handshake_completed)
    end

    # Check to make sure undefined, one and two arg versions of ssl_verify_peer work
    # (for backwards compatibility)
    def test_undefined
      begin
        EM.run do
          # no ssl_verify_peer defined
          EM.start_server("127.0.0.1", 16784, server(:verify_peer => true))
          EM.connect("127.0.0.1", 16784, client)
        end
      rescue Object # ArgumentError might suffice, but let's play it safe
        assert(false, 'should not have raised an exception')
      end
    end

    def test_one_arg_lambda
      begin
        EM.run do
          EM.start_server("127.0.0.1", 16784, server(:verify_peer => true) { |cert| true })
          EM.connect("127.0.0.1", 16784, client)
        end
      rescue Object # ArgumentError might suffice, but let's play it safe
        assert(false, 'should not have raised an exception')
      end
    end

    def test_two_arg_lambda
      begin
        EM.run do
          EM.start_server("127.0.0.1", 16784, server(:verify_peer => true) { |cert, preverify_ok| true })
          EM.connect("127.0.0.1", 16784, client)
        end
      rescue Object # ArgumentError might suffice, but let's play it safe
        assert(false, 'should not have raised an exception')
      end
    end
    
    def test_one_arg_method
      s = server(:verify_peer => true)
      s.module_eval do
        def ssl_verify_peer(cert) ; true ; end
      end
      begin
        EM.run do
          EM.start_server("127.0.0.1", 16784, s)
          EM.connect("127.0.0.1", 16784, client)
        end
      rescue Object # ArgumentError might suffice, but let's play it safe
        assert(false, 'should not have raised an exception')
      end
    end

    def test_two_arg_method
      s = server(:verify_peer => true)
      s.module_eval do
        def ssl_verify_peer(cert, preverify_ok) ; true ; end
      end
      begin
        EM.run do
          EM.start_server("127.0.0.1", 16784, s)
          EM.connect("127.0.0.1", 16784, client)
        end
      rescue Object # ArgumentError might suffice, but let's play it safe
        assert(false, 'should not have raised an exception')
      end
    end

    def test_no_ca_with_callback # [PASS]
      found_preverify_ok = nil
      EM.run do
        EM.start_server("127.0.0.1", 16784, server(:verify_peer => true) { |cert, preverify_ok| 
          found_preverify_ok = preverify_ok
        })
        EM.connect("127.0.0.1", 16784, client)
      end
      # without any CA file to check against, all clients should fail
      # the preverification
      assert_equal(false, found_preverify_ok)
    end

    def test_authorized_client_with_callback # [FAIL]
      found_preverify_ok = nil
      EM.run do
        EM.start_server("127.0.0.1", 16784, 
                        server(:verify_peer => true, :cert_auth_file => @dir+'ca-bundle-with-client-signer.crt') { |cert, preverify_ok| 
          found_preverify_ok = preverify_ok
        })
        EM.connect("127.0.0.1", 16784, client)
      end
      # if the CA file contains a cert that signed the client's cert
      # then the client should pass the preverification
      assert_equal(true, found_preverify_ok)
    end

    def test_unauthorized_client_with_callback # [PASS]
      found_preverify_ok = nil
      tf = Tempfile.new('em_test')
      tf.close
      EM.run do
        EM.start_server("127.0.0.1", 16784, 
                        server(:verify_peer => true, :cert_auth_file => @dir+'ca-bundle-without-client-signer.crt') { |cert, preverify_ok| 
          found_preverify_ok = preverify_ok
        })
        EM.connect("127.0.0.1", 16784, client)
      end
      # if the CA file doesn't contains a cert that signed the client's cert
      # then the client should not pass the preverification
      assert_equal(false, found_preverify_ok)
    ensure
      tf.unlink
    end

    def test_no_ca_default # [PASS]
      EM.run do
        EM.start_server("127.0.0.1", 16784, server(:verify_peer => true))
        EM.connect("127.0.0.1", 16784, client)
      end
      # without any CA file to check against,
      # if the server doesn't provide a ssl_verify_peer callback
      # the handshake should not complete.
      assert_equal(false, @server_handshake_completed)
      assert_equal(false, @client_handshake_completed)
    end

    def test_authorized_client_default # [FAIL]
      EM.run do
        EM.start_server("127.0.0.1", 16784, 
                        server(:verify_peer => true, :cert_auth_file => @dir+'ca-bundle-with-client-signer.crt'))
        EM.connect("127.0.0.1", 16784, client)
      end
      # if the CA file contains a cert that signed the client's cert
      # if the server doesn't provide a ssl_verify_peer callback
      # the handshake should complete.
      assert_equal(true, @server_handshake_completed)
      assert_equal(true, @client_handshake_completed)
    end

    def test_unauthorized_client_default # [PASS]
      tf = Tempfile.new('em_test')
      tf.close
      EM.run do
        EM.start_server("127.0.0.1", 16784, 
                        server(:verify_peer => true, :cert_auth_file => @dir+'ca-bundle-without-client-signer.crt'))
        EM.connect("127.0.0.1", 16784, client)
      end
      # if the CA file doesn't contains a cert that signed the client's cert
      # if the server doesn't provide a ssl_verify_peer callback
      # the handshake should not complete.
      assert_equal(false, @server_handshake_completed)
      assert_equal(false, @client_handshake_completed)
    ensure
      tf.unlink
    end
  end
else
  warn "EM built without SSL support, skipping tests in #{__FILE__}"
end
