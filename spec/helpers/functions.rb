module Functions
  include MockData

  # API call stubs for Source, endpoint, authentication(and credentials)
  def stub_api_source_calls(source)
    stub_api_source_get(source, show(source))
    endpoint = endpoints(source)[source['id']]
    stub_rest_get("#{sources_api}/sources/#{source["id"]}/endpoints", user_tenant_header, list([endpoint]))

    authentication = authentications(source)[source['id']]
    stub_rest_get("#{sources_api}/endpoints/#{endpoint['id']}/authentications", user_tenant_header, list([authentication]))

    stub_rest_get("#{sources_api(:internal => true)}/authentications/#{authentication['id']}?expose_encrypted_attribute[]=password", user_tenant_header, show(credentials(source)[authentication['id']]))
  end

  def stub_rest_get(path, tenant_header, response)
    expect(RestClient).to receive(:get).with(path, tenant_header).and_return(response)
  end

  def stub_rest_get_404(path, tenant_header)
    expect(RestClient).to receive(:get).with(path, tenant_header).and_raise(RestClient::NotFound)
  end

  def stub_rest_patch(path, body, tenant_header)
    expect(RestClient).to receive(:patch).with(path, body, tenant_header)
  end

  def stub_api_source_types_get(response)
    stub_rest_get("#{sources_api}/source_types", orchestrator_tenant_header, response)
  end

  def stub_api_application_types_get(response)
    stub_rest_get("#{sources_api}/application_types", orchestrator_tenant_header, response)
  end

  # Filter is based on TopologicalInventory::Orchestrator::Api#supported_applications_url
  # and mock_data.rb:application_types_data (id [1,3] includes topological-inventory)
  def stub_api_applications_get(response)
    application_query = "filter[application_type_id][eq][]=1&filter[application_type_id][eq][]=3"
    stub_rest_get("#{sources_api}/applications?#{application_query}", user_tenant_header, response)
  end

  def stub_api_tenants_get(response)
    stub_rest_get("#{topology_api(:internal => true)}/tenants", orchestrator_tenant_header, response)
  end

  def stub_api_source_get(source, response)
    stub_rest_get("#{sources_api}/sources/#{source["id"]}", user_tenant_header, response)
  end

  def stub_api_topology_sources_get(response)
    stub_rest_get("#{topology_api}/sources", user_tenant_header, response)
  end

  def stub_api_topology_sources_patch(source, body)
    path = "#{topology_api(:internal => true)}/sources/#{source["id"]}"
    stub_rest_patch(path, body, user_tenant_header)
  end

  def stub_api_source_refresh_status_patch(source, status)
    expect(%w[quota_limited deployed]).to include(status)

    stub_api_topology_sources_patch(source, { 'refresh_status' => status}.to_json)
  end

  # Initialize basic api calls which are called everytime
  # GET <sources_api>/source_types,
  # GET <tp-inv_api>/internal/tenants,
  # GET <tp-inv_api/sources
  #
  # @param[String<JSON>] source_types, tenants, topology_sources
  def stub_api_init(source_types:, tenants:, application_types:, applications:, topology_sources:)
    stub_api_source_types_get(source_types)
    stub_api_applications_get(applications)
    stub_api_application_types_get(application_types)
    stub_api_tenants_get(tenants)
    stub_api_topology_sources_get(topology_sources)
  end

  def list(data)
    { :links => {}, :data => data }.to_json
  end

  def show(data)
    data.to_json
  end

  def stub_settings_merge(hash)
    if defined?(::Settings)
      Settings.add_source!(hash)
      Settings.reload!
    end
  end

  def init_config(openshift: 1, amazon: 1, azure: 1, mock: 1)
    stub_settings_merge(:collectors => {
      :sources_per_collector => {
        :amazon    => amazon,
        :azure     => azure,
        :mock      => mock,
        :openshift => openshift
      }
    })
  end

  ### Assert checks agains kube_client
  def assert_openshift_objects_count(cnt)
    expect(kube_client.config_maps.size).to eq(cnt)
    expect(kube_client.deployment_configs.size).to eq(cnt)
    expect(kube_client.secrets.size).to eq(cnt)
  end

  def assert_openshift_objects_data(source_data, missing: false)
    config_uid = assert_source_in_config_maps(source_data, :missing => missing)
    assert_source_in_secrets(source_data, config_uid, :missing => missing)
  end

  def assert_source_in_config_maps(source_data, missing: false)
    found_digests, found_in_yaml = 0, 0
    config_uid = nil

    kube_client.config_maps.each_pair do |_name, config_map|
      source_source_type = source_type_for(source_data)&.send(:[], 'name')
      map_source_type = config_map.metadata.labels[TopologicalInventory::Orchestrator::ConfigMap::LABEL_SOURCE_TYPE.to_sym]

      expect(map_source_type).to be_present

      # Search config map if it contains digest of this source
      expect(config_map.data.digests).to be_present
      digests = JSON.parse(config_map.data.digests)

      if (found_digest = digests.include?(digests_data[source_data['id']]))
        found_digests += 1

        # When found, check that source is in config_map of the same source_type
        expect(map_source_type == source_source_type)

        # Get config id
        config_uid = config_map.metadata.labels[TopologicalInventory::Orchestrator::ConfigMap::LABEL_UNIQUE.to_sym]
      end

      # Search config map if it contains source in custom.yml
      data = YAML.load(config_map.data['custom.yml'])
      data[:sources].each do |yaml_source|
        if yaml_source[:source] == source_data['uid']
          found_in_yaml += 1
          expect(found_digest)

          # Check that endpoint data are written to custom.yml
          endpoint = endpoints(source_data)[source_data['id']]

          expect(endpoint['scheme']).to eq(yaml_source[:scheme])
          expect(endpoint['host']).to eq(yaml_source[:host])
          expect(endpoint['port']).to eq(yaml_source[:port])
          expect(endpoint['path']).to eq(yaml_source[:path])
        end
      end
    end

    if missing
      # If checked for missing data, source wasn't found
      expect(found_digests).to eq(0)
      expect(found_in_yaml).to eq(0)
    else
      # Otherwise ensure that data are written only once
      expect(found_digests).to eq(1)
      expect(found_in_yaml).to eq(1)
    end

    config_uid
  end

  def assert_source_in_secrets(source_data, config_uid, missing: false)
    found_cnt = 0
    kube_client.secrets.each_value do |secret|
      expect(secret.stringData.credentials).to be_present
      data = JSON.parse(secret.stringData.credentials)

      if (secret_creds = data[source_data['uid']]).present?
        found_cnt += 1
        # Check that authentication data are written to secret's data
        auth = credentials(source_data)[source_data['id']]

        expect(auth['username']).to eq(secret_creds['username'])
        expect(auth['password']).to eq(secret_creds['password'])

        # Check we're in secret connected to config map with the same UID
        secret_uid = secret.metadata.labels[TopologicalInventory::Orchestrator::Secret::LABEL_UNIQUE.to_sym]
        expect(secret_uid).to eq(config_uid)
      end
    end

    expect(found_cnt).to eq(missing ? 0 : 1)
  end

  def assert_deployment_config(_source_data, config_uid)
    found = false
    kube_client.deployment_configs.each_value do |dc|
      break if found

      dc_uid = dc.metadata.labels[TopologicalInventory::Orchestrator::DeploymentConfig::LABEL_UNIQUE.to_sym]
      found = dc_uid == config_uid
    end

    expect(found).to eq(true)

    # TODO: Check mounts
  end
end
