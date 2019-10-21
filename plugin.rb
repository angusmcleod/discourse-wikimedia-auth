# name: discourse-wikimedia-auth
# about: Enable Login via Wikimedia
# version: 0.0.1
# authors: Angus McLeod
# url: https://github.com/paviliondev/discourse-wikimedia-auth

gem 'omniauth-mediawiki', '0.0.4'

enabled_site_setting :wikimedia_auth_enabled

register_asset 'stylesheets/common/wikimedia.scss'

module WikimediaUsername
  def self.adapt(username)
    UserNameSuggester.suggest(username&.unicode_normalize)
  end
end

class WikimediaAuthenticator < ::Auth::ManagedAuthenticator
  def name
    'mediawiki'
  end
  
  def primary_email_verified?(auth_token)
    auth_token[:extra]['confirmed_email'].present? ?
    auth_token[:extra]['confirmed_email'] :
    false
  end
  
  def can_revoke?
    false
  end
  
  def can_connect_existing_user?
    false
  end
  
  def always_update_user_username?
    SiteSetting.wikimedia_username_conformity_login
  end

  def after_authenticate(auth_token, existing_account: nil)
    raw_info = auth_token[:extra]['raw_info']
    auth_token[:extra] = raw_info || {}
    
    ## Deny entry if either:
    # 1) the user's Wikimedia email is not verified; or
    # 2) a user has previously authenticated with the same email under a different Wikimedia account
    ##

    if !primary_email_verified?(auth_token) ||
       (existing_associated_account = ::UserAssociatedAccount.where(
        "info::json->>'email' = '#{raw_info['email']}' AND
         provider_uid != '#{raw_info['sub']}'").exists?)
      
      error_result = Auth::Result.new
      error_result.failed = true
      error_result.failed_reason = existing_associated_account ?
        I18n.t("login.authenticator_existing_account", { email: raw_info['email']}) :
        I18n.t("login.authenticator_email_not_verified")

      error_result
    else
      auth_token[:info][:nickname] = raw_info['username'] if raw_info['username']
      auth_result = super(auth_token, existing_account: existing_account)
      
      ## Update user's username from the auth payload
      if auth_result.user &&
          always_update_user_username? &&
          auth_result.username
                
        UsernameChanger.change(
          auth_result.user,
          WikimediaUsername.adapt(auth_result.username),
          Discourse.system_user
        )
      end
      
      auth_result.omit_username = true
      auth_result
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
                        options[:client_options][:site] = SiteSetting.wikimedia_auth_site
                        
                        def strategy.callback_url
                          SiteSetting.wikimedia_callback_url
                        end
                      }
  end

  def enabled?
    SiteSetting.wikimedia_auth_enabled
  end
end

auth_provider authenticator: WikimediaAuthenticator.new

after_initialize do
  module UsersControllerExtension
    def create
      ## Ensure that username sent by the client is the same as suggester's version of the Wikimedia username
      ## Note that email is ensured by the email validation process
      
      wikimedia_username = WikimediaUsername.adapt(session[:authentication][:username])
      
      if wikimedia_username != params[:username]
        return fail_with("login.non_wikimedia_username")
      end
        
      super
    end
  end
  
  require_dependency 'users_controller'
  class ::UsersController
    prepend UsersControllerExtension
  end
  
  module GuardianWikimediaExtension
    def can_edit_username?(user)
      return false if !is_admin? && SiteSetting.wikimedia_auth_enabled
      super(user)
    end
  end
  
  require_dependency 'guardian'
  class ::Guardian
    prepend GuardianWikimediaExtension
  end
end