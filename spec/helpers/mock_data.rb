module MockData
  def sources_api(internal: false)
    if internal
      "http://sources.local:8080/internal/v1.0"
    else
      "http://sources.local:8080/api/sources/v1.0"
    end
  end

  def topology_api(internal: false)
    if internal
      "http://topology.local:8080/internal/v1.0"
    else
      "http://topology.local:8080/api/topological-inventory/v1.0"
    end
  end

  def user_tenant_account
    "12345"
  end

  def user2_tenant_account
    "234567"
  end

  def user_tenant_header
    {"x-rh-identity" => "eyJpZGVudGl0eSI6eyJhY2NvdW50X251bWJlciI6IjEyMzQ1IiwidXNlciI6eyJpc19vcmdfYWRtaW4iOnRydWV9fX0="}
  end

  def user2_tenant_header
    {"x-rh-identity" => "eyJpZGVudGl0eSI6eyJhY2NvdW50X251bWJlciI6IjIzNDU2NyIsInVzZXIiOnsiaXNfb3JnX2FkbWluIjp0cnVlfX19"}
  end

  def orchestrator_tenant_header
    {"x-rh-identity" => "eyJpZGVudGl0eSI6eyJhY2NvdW50X251bWJlciI6InN5c3RlbV9vcmNoZXN0cmF0b3IiLCJ1c2VyIjp7ImlzX29yZ19hZG1pbiI6dHJ1ZX19fQ==" }
  end

  def tenants
    {
      user_tenant_account  => {"id" => "1", "external_tenant" => user_tenant_account},
      user2_tenant_account => {"id" => "2", "external_tenant" => user2_tenant_account}
    }
  end

  def source_types_data
    {
      :openshift => {"id" => "1", "name" => "openshift", "product_name" => "OpenShift", "vendor" => "Red Hat", "collector_image" => "abc123"},
      :amazon    => {"id" => "2", "name" => "amazon", "product_name" => "Amazon AWS", "vendor" => "Amazon", "collector_image" => "abc123"},
      :azure     => {"id" => "3", "name" => "azure", "product_name" => "Azure", "vendor" => "Azure", "collector_image" => "abc123"},
      :mock      => {"id" => "4", "name" => "mock", "product_name" => "Azure", "vendor" => "Azure", "collector_image" => "abc123"},
    }
  end

  def sources_data
    hash = {}

    # Tenant: user
    add_source(hash, '1', :type => :openshift, :uid => 'cacebc33-1ed8-49d4-b4f9-713f2552ee65', :availability_status => 'available')
    add_source(hash, '2', :type => :openshift, :uid => '31b5338b-685d-4056-ba39-d00b4d7f19cc', :availability_status => 'unavailable')
    add_source(hash, '3', :type => :openshift, :uid => '95f057b7-ec11-4f04-b155-e54dcd5b01aa', :availability_status => 'available')
    add_source(hash, '4', :type => :amazon, :uid => '15493710-8a96-4516-a0de-a9349ba61b9c', :availability_status => 'available')
    add_source(hash, '5', :type => :amazon, :uid => 'a3e42e0b-0902-4911-a0cd-356bd3cf684e', :availability_status => 'available')
    add_source(hash, '6', :type => :amazon, :uid => '86094174-5ae9-476b-8ff5-7c24e01e380d', :availability_status => 'unavailable')
    add_source(hash, '7', :type => :azure, :uid => '4a31b8be-57fc-44e6-899d-d92c3ccc6552')
    add_source(hash, '8', :type => :azure, :uid => '9fe99b8c-2cfa-43d8-a695-bf01a535f897')
    add_source(hash, '9', :type => :azure, :uid => 'e4c89509-7177-4f56-8fcc-3015c390c4e7')
    add_source(hash, '10', :type => :mock, :uid => '8d8d6d75-a1c0-417c-933e-c8f254307cb1')
    add_source(hash, '11', :type => :mock, :uid => '232dce7e-0f89-4601-8796-f3af43618f62')
    add_source(hash, '12', :type => :mock, :uid => 'bfd2da99-722b-4ba3-9606-393c1b8c79f4')
    # Tenant: user2
    add_source(hash, '13', :type => :azure, :uid => '2fec8712-ee07-4a4b-9461-dc6dce35cc80', :availability_status => 'available', :tenant => user2_tenant_account)
    hash
  end

  def available_sources_data(type)
    sources_data[type].select { |_key, source| source_available?(source) }
  end

  def source_available?(source)
    return true unless supports_availability_check?(source["type"])

    source["availability_status"] == "available"
  end

  def supports_availability_check?(type)
    TopologicalInventory::Orchestrator::SourceType::AVAILABILITY_CHECK_SOURCE_TYPES.include?(type.to_s)
  end

  def topological_sources
    hash = {}
    # tenant: user
    add_source(hash, '1', :topological => true, :type => :openshift, :uid => 'cacebc33-1ed8-49d4-b4f9-713f2552ee65')
    add_source(hash, '2', :topological => true, :type => :openshift, :uid => '31b5338b-685d-4056-ba39-d00b4d7f19cc')
    add_source(hash, '3', :topological => true, :type => :openshift, :uid => '95f057b7-ec11-4f04-b155-e54dcd5b01aa')
    add_source(hash, '4', :topological => true, :type => :amazon, :uid => '15493710-8a96-4516-a0de-a9349ba61b9c')
    add_source(hash, '5', :topological => true, :type => :amazon, :uid => 'a3e42e0b-0902-4911-a0cd-356bd3cf684e')
    add_source(hash, '6', :topological => true, :type => :amazon, :uid => '86094174-5ae9-476b-8ff5-7c24e01e380d')
    add_source(hash, '7', :topological => true, :type => :azure, :uid => '4a31b8be-57fc-44e6-899d-d92c3ccc6552')
    add_source(hash, '8', :topological => true, :type => :azure, :uid => '9fe99b8c-2cfa-43d8-a695-bf01a535f897')
    add_source(hash, '9', :topological => true, :type => :azure, :uid => 'e4c89509-7177-4f56-8fcc-3015c390c4e7')
    add_source(hash, '10', :topological => true, :type => :mock, :uid => '8d8d6d75-a1c0-417c-933e-c8f254307cb1')
    add_source(hash, '11', :topological => true, :type => :mock, :uid => '232dce7e-0f89-4601-8796-f3af43618f62')
    add_source(hash, '12', :topological => true, :type => :mock, :uid => 'bfd2da99-722b-4ba3-9606-393c1b8c79f4')

    # tenant: user2
    add_source(hash, '13', :topological => true, :type => :azure, :uid => '2fec8712-ee07-4a4b-9461-dc6dce35cc80', :tenant => user2_tenant_account)

    hash
  end

  def application_types_data
    [
      {
        :dependent_applications         => ["/insights/platform/topological-inventory"],
        :display_name                   => "Catalog",
        :id                             => '1',
        :name                           => "/insights/platform/catalog",
        :supported_authentication_types => {:ansible_tower => ["username_password"]},
        :supported_source_types         => ["ansible_tower"]
      },
      {
        :dependent_applications         => [],
        :display_name                   => "Cost Management",
        :id                             => "2",
        :name                           => "/insights/platform/cost-management",
        :supported_authentication_types => {:amazon => ["arn"]},
        :supported_source_types         => ["amazon"]
      },
      {
        :dependent_applications         => [],
        :display_name                   => "Topological Inventory",
        :id                             => "3",
        :name                           => "/insights/platform/topological-inventory",
        :supported_authentication_types => {
          :amazon        => ["access_key_secret_key"],
          :ansible_tower => ["username_password"],
          :azure         => ["username_password"],
          :openshift     => ["token"]
        },
        :supported_source_types         => ["amazon", "ansible_tower", "azure", "openshift"]
      }
    ]
  end

  def applications_data(source = nil)
    hash = {}

    if source.nil?
      sources_data.each_pair do |_type, sources_hash|
        sources_hash.each_pair do |id, src|
          hash[id] = add_application(id, :tenant => src['tenant'])
        end
      end
    else
      hash[source['id']] = add_application(source['id'], :tenant => source['tenant'])
    end
    hash
  end

  def endpoints(source = nil)
    hash = {}

    if source.nil?
      sources_data.each_pair do |_type, sources_hash|
        sources_hash.each_pair do |id, src|
          hash[id] = add_endpoint(id, :tenant => src['tenant'])
        end
      end
    else
      hash[source['id']] = add_endpoint(source['id'], :tenant => source['tenant'])
    end
    hash
  end

  def authentications(source = nil)
    hash = {}

    if source.nil?
      sources_data.each_pair do |_type, sources_hash|
        sources_hash.each_pair do |id, src|
          hash[id] = add_authentication(id, :tenant => src['tenant'])
        end
      end
    else
      hash[source['id']] = add_authentication(source['id'], :tenant => source['tenant'])
    end
    hash
  end

  def credentials(source = nil)
    hash = {}

    if source.nil?
      sources_data.each_pair do |_type, sources_hash|
        sources_hash.each_pair do |id, src|
          hash[id] = add_credential(id, :tenant => src['tenant'])
        end
      end
    else
      hash[source['id']] = add_credential(source['id'], :tenant => source['tenant'])
    end
    hash
  end

  # Values are for source + endpoint + credentials of the same ID
  def digests_data
    {
      '1'  => '7a8a3dad389031160f79817c14bb5f3adf058335',
      '2'  => '8d4fc3e19f141135ca59f0ba5d9e8b634f04840e',
      '3'  => '88f879b8aa22eb340019449955accdca62886f64',
      '4'  => 'dba9f7cc5b15cc2eee74a288e6c04431d2f5e509',
      '5'  => 'febf0d5b94e4dd2cd23f3a9cd515641885a50980',
      '6'  => '2628bf51107c4c5cd581179df5d1148821f8a7a8',
      '7'  => '83f929fdce5dfe931f9ccc6af49e2cfd436740f4',
      '8'  => '5f9e781563ab48e7a67ec4500321b1ebe553f3fc',
      '9'  => '8b14bf8dfa2bc7d74443cd9c4a0d836f1341becb',
      '10' => '5442273b216f7c843de10acc57c33638f7848f74',
      '11' => '3871068443e406fbff7ad6f91bd395bf9482a259',
      '12' => '9e52c47b63dd968ba2349779a86986eff2f2b860',
      '13' => '658ba6008127dc4e61eb5bbe70ec69be5524b845'
    }
  end

  def source_type_for(source)
    source_types_data.values.detect { |type| type['id'] == source['source_type_id'] }
  end

  private

  def add_source(out, id, topological: false, type:, uid:, availability_status: nil, tenant: user_tenant_account)
    out[type] ||= {}
    new_source = if topological
                   {
                     'id'        => id.to_s,
                     'type'      => type.to_s,
                     'uid'       => uid,
                     'tenant_id' => tenants[tenant]['id']
                   }
                 else
                   {
                     'id'                  => id.to_s,
                     'type'                => type.to_s,
                     'source_type_id'      => (source_types_data[type] || {})['id'],
                     'name'                => "#{type}#{id}",
                     'uid'                 => uid,
                     'tenant'              => tenants[tenant]['external_tenant'],
                     'availability_status' => availability_status
                   }
                 end
    out[type][id] = new_source
    new_source
  end

  # 1:1 source-application
  def add_application(source_id, tenant: user_tenant_account)
    {'id' => source_id.to_s, 'application_type_id' => '1', 'source_id' => source_id.to_s, 'tenant' => tenants[tenant]['external_tenant']}
  end

  # 1:1 source-endpoint
  def add_endpoint(source_id, tenant: user_tenant_account)
    {'id' => source_id.to_s, 'source_id' => source_id.to_s, 'default' => true, 'tenant' => tenants[tenant]['external_tenant'], "host" => "example.com", "path" => "/api", "port" => 8443, "scheme" => "https"}
  end

  # 1:1:1 source-endpoint-authentication
  def add_authentication(source_id, tenant: user_tenant_account)
    {'id' => source_id.to_s, 'resource_id' => source_id.to_s, 'resource_type' => 'Endpoint', 'tenant' => tenants[tenant]['external_tenant']}
  end

  # 1:1 with authentication (same records)
  def add_credential(source_id, tenant: user_tenant_account)
    {'id' => source_id.to_s, 'username' => 'admin', 'password' => 'smartvm', 'resource_id' => source_id.to_s, 'resource_type' => 'Endpoint', 'tenant' => tenants[tenant]['external_tenant']}
  end
end
