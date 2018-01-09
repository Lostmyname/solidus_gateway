module Spree
  class Gateway::StripeGateway < Spree::PaymentMethod::CreditCard
    preference :secret_key, :string
    preference :publishable_key, :string

    CARD_TYPE_MAPPING = {
      'American Express' => 'american_express',
      'Diners Club' => 'diners_club',
      'Visa' => 'visa'
    }

    if SolidusSupport.solidus_gem_version < Gem::Version.new('2.3.x')
      def method_type
        'stripe'
      end
    else
      def partial_name
        'stripe'
      end
    end

    def gateway_class
      ActiveMerchant::Billing::StripeGateway
    end

    def payment_profiles_supported?
      true
    end

    def purchase(money, creditcard, gateway_options)
      money = localize_money(money, gateway_options)
      gateway.purchase(*options_for_purchase_or_auth(money, creditcard, gateway_options))
    end

    def authorize(money, creditcard, gateway_options)
      money = localize_money(money, gateway_options)
      gateway.authorize(*options_for_purchase_or_auth(money, creditcard, gateway_options))
    end

    def capture(money, response_code, gateway_options)
      money = localize_money(money, gateway_options)
      gateway.capture(money, response_code, gateway_options)
    end

    def credit(money, creditcard, response_code, gateway_options)
      money = localize_money(money, gateway_options)
      gateway.refund(money, response_code, {})
    end

    def void(response_code, creditcard, gateway_options)
      gateway.void(response_code, {})
    end

    def cancel(response_code)
      gateway.void(response_code, {})
    end

    def create_profile(payment)
      return unless payment.source.gateway_customer_profile_id.nil?
      options = {
        email: payment.order.email,
        login: preferred_secret_key,
      }.merge! address_for(payment)

      source = update_source!(payment.source)
      if source.number.blank? && source.gateway_payment_profile_id.present?
        creditcard = source.gateway_payment_profile_id
      else
        creditcard = source
      end

      response = gateway.store(creditcard, options)
      if response.success?
        payment.source.update_attributes!({
          cc_type: payment.source.cc_type, # side-effect of update_source!
          gateway_customer_profile_id: response.params['id'],
          gateway_payment_profile_id: response.params['default_source'] || response.params['default_card']
        })

      else
        payment.send(:gateway_error, response.message)
      end
    end

    private

    def non_fractional_currency?(currency)
      gateway_class.currencies_without_fractions.include?(currency.to_s)
    end

    def localize_money(money, gateway_options)
      currency = gateway_options[:currency]
      # We have this hack in place because in `activemerchant` the library
      # automatically divides the number by 100, therefore we end up charging
      # the customer much less than what we intened to do
      # Example: pass 3000JPY, divide by 100, try to charge 30JPY.
      # This is also detailed in https://github.com/activemerchant/active_merchant/issues/1794
      # and original issue at: https://github.com/activemerchant/active_merchant/issues/1153
      # The code that divides by 100 is at: https://github.com/activemerchant/active_merchant/blob/master/lib/active_merchant/billing/gateway.rb#L266-L276
      # (this only affected non-fractional currencies)
      # Also someone tried to fix this https://github.com/activemerchant/active_merchant/pull/2314
      # and the conclusion was that there was a need for a major version release
      # which for Activemerchant hasn't happened in a good few years.
      # https://github.com/activemerchant/active_merchant/issues/1943 - also
      # PayPal charge works, but refunds are broken.
      if non_fractional_currency?(currency)
        money * 100
      else
        money
      end
    end

    # In this gateway, what we call 'secret_key' is the 'login'
    def options
      options = super
      options.merge(:login => preferred_secret_key)
    end

    def options_for_purchase_or_auth(money, creditcard, gateway_options)
      options = {}
      options[:description] = "Spree Order ID: #{gateway_options[:order_id]}"
      options[:currency] = gateway_options[:currency]

      customer      = creditcard.gateway_customer_profile_id
      if token_or_card = creditcard.gateway_payment_profile_id
        if token_or_card =~ /^\w*tok_/
          token = token_or_card
        else
          card = token_or_card
        end
      end

      payment_object = if token
        token
      elsif card
        "#{customer}|#{card}"
      else
        creditcard
      end

      return money, payment_object, options
    end

    def address_for(payment)
      {}.tap do |options|
        if address = payment.order.bill_address
          options.merge!(address: {
            address1: address.address1,
            address2: address.address2,
            city: address.city,
            zip: address.zipcode
          })

          if country = address.country
            options[:address].merge!(country: country.name)
          end

          if state = address.state
            options[:address].merge!(state: state.name)
          end
        end
      end
    end

    def update_source!(source)
      source.cc_type = CARD_TYPE_MAPPING[source.cc_type] if CARD_TYPE_MAPPING.include?(source.cc_type)
      source
    end
  end
end
