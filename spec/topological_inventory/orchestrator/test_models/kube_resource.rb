module TopologicalInventory
  module Orchestrator
    module TestModels
      class KubeResource < ::Kubeclient::Resource
        def initialize(hash = nil, args = {})
          hash[:data] = encode_secrets(hash.delete(:stringData)) if hash.present? && hash.key?(:stringData)
          super(hash, args)
        end

        def stringData=(hash)
          send(:data=, encode_secrets(hash))
        end

        private

        # This probably works in more generic way, but for testing purposes it's ok
        def encode_secrets(data)
          data[:credentials] = Base64.encode64(data[:credentials]) if data[:credentials]
          data['credentials'] = Base64.encode64(data['credentials']) if data['credentials']
          data
        end
      end
    end
  end
end
