# name: discourse-wikimedia-auth
# about: Enable Login via Wikimedia
# version: 0.0.1
# authors: Angus McLeod
# url: https://github.com/paviliondev/discourse-wikimedia-auth

gem 'omniauth-mediawiki', '0.0.4'

register_svg_icon "wikipedia-w" if respond_to?(:register_svg_icon)
enabled_site_setting :wikimedia_auth_enabled

class WikimediaAuthenticator < ::Auth::ManagedAuthenticator
  def name
    'mediawiki'
  end
  
  def primary_email_verified?(auth_token)
    auth_token[:extra]['raw_info']['confirmed_email']
  end
  
  def can_connect_existing_user?
    false
  end

  def after_authenticate(auth_token)
    if !primary_email_verified?(auth_token)
      result = Auth::Result.new
      result.failed = true
      result.failed_reason = I18n.t("login.authenticator_email_not_verified")
      result
    else
      raw_info = auth_token[:extra]['raw_info']
      auth_token[:info][:nickname] = raw_info['username'] if raw_info['username']
      auth_token[:info][:name] = raw_info['realname'] if raw_info['realname']
      
      super(auth_token, existing_account: nil)
    end
  end

  def register_middleware(omniauth)
    omniauth.provider :mediawiki,
                      name: name,
                      setup: lambda { |env|
                        strategy = env['omniauth.strategy']
                        options = strategy.options
                        options[:consumer_key] = SiteSetting.wikimedia_consumer_key
                        options[:consumer_secret] = SiteSetting.wikimedia_consumer_secret
                        
                        def strategy.callback_url
                          SiteSetting.wikimedia_callback_url
                        end
                      }
  end

  def enabled?
    SiteSetting.wikimedia_auth_enabled
  end
end

auth_provider icon: 'wikipedia-w',
              authenticator: WikimediaAuthenticator.new