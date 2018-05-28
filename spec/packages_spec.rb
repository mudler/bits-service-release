# frozen_string_literal: true

require 'spec_helper'
require 'shared_examples'
require 'json'
require 'support/cf.rb'
require "rspec/json_expectations"

require 'support/environment'
require 'support/manifest'


RSpec.configure {
  include EnvironmentHelpers
  include ManifestHelpers
}

describe 'packages resource' do
  let(:resource_path) { "/packages/#{guid}" }
  let(:upload_body) { { package: zip_file } }
  let(:blobstore_client) { backend_client(:packages) }
  let(:zip_filepath) { File.expand_path('../assets/empty.zip', __FILE__) }
  let(:zip_file) { File.new(zip_filepath) }
  let(:guid) do
    if !cc_updates_enabled?
      SecureRandom.uuid
    else
      @cf_client.create_package(@app_id)
    end
  end
  let(:existing_guid) do
    if !cc_updates_enabled?
      SecureRandom.uuid
    else
      @cf_client.create_package(@app_id)
    end.tap do |guid|
      make_put_request "/packages/#{guid}", upload_body
    end
  end

  before :all do
    if cc_updates_enabled?
      @cf_client = CFClient::Client.new(cc_api_url, cc_user, cc_password)
      @org_id = @cf_client.create_org
      expect(@org_id).to_not be_empty
      @space_id = @cf_client.create_space(@org_id)
      expect(@space_id).to_not be_empty
      @app_id = @cf_client.create_app(@space_id)
      expect(@app_id).to_not be_empty
    end
  end
  after :all do
    if cc_updates_enabled?
      @cf_client.delete_org(@org_id)
      expect(@cf_client.get_org(@org_id)['error_code']).to eq('CF-OrganizationNotFound')
    end
  end

  after action: :upload do
    expect(blobstore_client.delete_resource(guid)).to be_truthy
    expect(blobstore_client.key_exist?(guid)).to eq(false)
  end
  after action: :upload_existing do
    expect(blobstore_client.delete_resource(existing_guid)).to be_truthy
    expect(blobstore_client.key_exist?(existing_guid)).to eq(false)
  end

  describe 'PUT /packages/:guid', type: :integration do
    context 'when package is uploaded', action: :upload do
      it 'returns HTTP status 201' do
        response = make_put_request resource_path, upload_body
        expect(response.code).to eq 201
      end

      it 'stores the blob in the backend' do
        make_put_request resource_path, upload_body
        expect(blobstore_client.key_exist?(guid)).to eq(true)
      end

      context 'when the request body is invalid', action: false do
        let(:upload_body) { {} }

        it 'returns HTTP status 4XX' do
          response = make_put_request resource_path, upload_body
          expect(response.code).to eq 400
        end
      end

      include_examples 'when blobstore disk is full', :packages
    end

    context 'when package is duplicated' do
      # Since we cannot create a package in CC with COPYING state easily, we
      # decided to not test this behavior when CC updates are enabled.
      context 'when the package exists', if: !cc_updates_enabled?, action: %i[upload upload_existing] do
        it 'returns HTTP status 201' do
          response = make_put_request resource_path, JSON.generate(source_guid: existing_guid)
          expect(response.code).to eq 201
        end

        it 'returns the guid and the package exists' do
          make_put_request resource_path, JSON.generate(source_guid: existing_guid)
          expect(blobstore_client.key_exist?(guid)).to eq(true)
        end
      end

      context 'when the package does not exist' do
        it 'returns the correct error' do
          response = make_put_request resource_path, JSON.generate(source_guid: 'invalid-guid')
          expect(response).to be_a_404
        end
      end

      context 'when the body is invalid' do
        it 'returns the correct error' do
          response = make_put_request resource_path, 'foobar'
          expect(response.code).to eq(400)
        end
      end

      context 'when the body is empty' do
        it 'returns the correct error' do
          response = make_put_request resource_path, ''
          expect(response.code).to eq(400)
        end
      end
    end

    context 'when multipart param is called "bits" (as done by cf CLI), not "package" (as done by CC)' do
      let(:upload_body) { { bits: zip_file } }

      it 'returns HTTP status 201 and a json body acceptable for the cf CLI' do
        response = make_put_request resource_path, upload_body

        expect(response.code).to eq(201)

        expect(JSON.parse(response.body)).to include_json(
          guid: guid,
          state: 'READY',
          type: 'bits',
          created_at: /.+/
        )
      end
    end

    context 'when the PUT is not a multipart request' do
      let(:upload_body) { {} }

      it 'returns HTTP status 4XX' do
        response = make_put_request resource_path, upload_body
        expect(response.code).to eq 400
      end
    end

    context 'with CC updates enabled', if: cc_updates_enabled? do
      it 'does not allow to upload the same package twice' do
        package_upload_url = @cf_client.package(@cf_client.create_package(@app_id))['links']['upload']['href']

        response = RestClient::Resource.new(package_upload_url, verify_ssl: OpenSSL::SSL::VERIFY_NONE).put upload_body

        expect(response.code).to be_between(200, 204), "First upload to \"#{package_upload_url}\" should succeed"

        # zip_file from upload_body is already closed by now, so we can't reuse it:
        begin
          response = RestClient::Resource.new(package_upload_url, verify_ssl: OpenSSL::SSL::VERIFY_NONE).
            put({ package: File.new(zip_filepath) })
          fail "upload to \"#{package_upload_url}\" should not succeed"
        rescue RestClient::ExceptionWithResponse => e
          expect(e.response.code).to eq(400)
          err = JSON.parse(e.response)
          expect(err['code']).to eq(290008)
          expect(err['description']).to eq('Cannot update an existing package.')
        end
      end
    end
  end

  describe 'GET /packages/:guid', type: :integration do
    context 'when the package exists', action: :upload do
      let(:guid) { existing_guid }
      let(:resource_path) { "/packages/#{existing_guid}" }

      it 'returns HTTP status 200' do
        response = make_get_request resource_path
        expect(response.code).to eq 200
      end

      it 'returns the correct contents' do
        response = make_get_request resource_path
        expect(response.body).to eq File.open(zip_filepath, 'rb').read
      end
    end

    context 'when the package does not exist' do
      let(:resource_path) { '/packages/not-existing' }

      it 'returns the correct error' do
        response = make_get_request resource_path
        expect(response).to be_a_404
      end
    end
  end

  describe 'DELETE /packages/:guid', type: :integration do
    context 'when the package exists' do
      let(:resource_path) { "/packages/#{existing_guid}" }

      it 'returns HTTP status 204' do
        response = make_delete_request resource_path
        expect(response.code).to eq 204
      end

      it 'deletes the blob from the backend' do
        make_delete_request resource_path
        expect(blobstore_client.key_exist?(guid)).to eq(false)
      end
    end

    context 'when the package does not exist' do
      let(:resource_path) { '/packages/not-existing' }

      it 'has HTTP 404 as status code' do
        response = make_delete_request resource_path
        expect(response.code).to eq 404
      end

      it 'returns the correct error' do
        response = make_delete_request resource_path
        expect(response).to be_a_404
      end
    end
  end
end
