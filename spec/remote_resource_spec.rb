require 'spec_helper'

RSpec.describe 'remote resources' do
  let(:klass) do
    Class.new(Graphiti::Resource) do
      self.remote = 'http://foo.com/api/v1/employees'

      attribute :last_name, :string do # override
        @object.last_name.upcase
      end
      attribute :full_name, :string do
        "#{@object.first_name} #{@object.last_name}"
      end
    end
  end

  def assert_params(params)
    expect(Faraday).to receive(:get)
      .with("http://foo.com/api/v1/employees?#{params}", anything, anything)
    get_data
  end

  def assert_headers(headers, ctx = {})
    expected = hash_including(headers)
    expect(Faraday).to receive(:get)
      .with(anything, anything, expected)
      .and_return(response_object)
    Graphiti.with_context ctx do
      get_data
    end
  end

  let(:params) { {} }
  let(:query) { klass.all(params) }
  let(:response_object) { double(body: response.to_json) }
  let(:response) do
    {
      data: [
        id: '123',
        type: 'employees',
        attributes: {
          first_name: 'Jane',
          last_name: 'Doe'
        }
      ]
    }
  end

  subject(:get_data) { query.data }

  before do
    allow(Faraday).to receive(:get) { response_object }
  end

  context 'when basic query' do
    it 'hits remote endpoint' do
      expect(Faraday).to receive(:get)
        .with('http://foo.com/api/v1/employees', anything, anything)
        .and_return(response_object)
      get_data
    end

    it 'returns models based on the response' do
      data = get_data
      expect(data.length).to eq(1)
      model = data[0]
      expect(model.id).to eq('123')
      expect(model._type).to eq('employees')
      expect(model.first_name).to eq('Jane')
      expect(model.last_name).to eq('Doe')
      expect(model.to_h).to_not have_key(:_relationships)
    end

    it 'can serialize correctly' do
      json = JSON.parse(query.to_jsonapi)
      data = json['data'][0]
      expect(data['id']).to eq('123')
      expect(data['type']).to eq('employees')
      expect(data['attributes']).to eq({
        'first_name' => 'Jane',
        'last_name' => 'DOE',
        'full_name' => 'Jane Doe'
      })
      expect(json['meta']).to eq({})
    end

    context 'when remote_base_url is set' do
      before do
        klass.class_eval do
          self.remote_base_url = 'http://all-about-that-base.com'
          self.remote = '/api/v1/employees'
        end
      end

      it 'is used' do
        expect(Faraday).to receive(:get)
          .with('http://all-about-that-base.com/api/v1/employees', anything, anything)
          .and_return(response_object)
        get_data
      end
    end

    context 'when custom timeout' do
      before do
        klass.timeout = 7
      end

      it 'is set correctly' do
        req = OpenStruct.new(options: OpenStruct.new)
        allow(Faraday).to receive(:get)
          .and_yield(req).and_return(response_object)
        get_data
        expect(req.options.timeout).to eq(7)
      end
    end

    context 'when custom open_timeout' do
      before do
        klass.open_timeout = 14
      end

      it 'is set correctly' do
        req = OpenStruct.new(options: OpenStruct.new)
        allow(Faraday).to receive(:get)
          .and_yield(req).and_return(response_object)
        get_data
        expect(req.options.open_timeout).to eq(14)
      end
    end

    context 'when customizing faraday request' do
      before do
        klass.class_eval do
          def make_request(url)
            super do |req|
              req.headers['Foo-Bar'] = 'Baz'
            end
          end
        end
      end

      it 'works' do
        req = OpenStruct.new(options: OpenStruct.new, headers: OpenStruct.new)
        allow(Faraday).to receive(:get)
          .and_yield(req).and_return(response_object)
        get_data
        expect(req.headers['Foo-Bar']).to eq('Baz')
      end
    end

    context 'when an error on the remote' do
      context 'and the response has raw error' do
        let(:response) do
          {
            errors: [{
              meta: {
                __raw_error__: {
                  message: 'foo bar',
                  backtrace: ['a', 'b']
                }
              }
            }]
          }
        end

        it 'is raised correctly' do
          expect {
            get_data
          }.to raise_error(Graphiti::Errors::Remote, /foo bar/)
        end
      end

      context 'and the response does not have raw error' do
        let(:response) do
          {
            errors: [{
              title: 'Error',
              detail: 'On some thing'
            }]
          }
        end

        it 'is raised correctly' do
          expect {
            get_data
          }.to raise_error(Graphiti::Errors::Remote, /Error - On some thing/)
        end
      end
    end

    context 'when overriding headers' do
      before do
        klass.class_eval do
          def request_headers
            { 'Some-Foo' => 'bar' }
          end
        end
      end

      it 'works' do
        assert_headers('Some-Foo' => 'bar')
      end

      it 'still sends the JSONAPI Content-Type header' do
        assert_headers('Content-Type' => 'application/vnd.api+json')
      end
    end

    context 'when Rails' do
      before do
        stub_const('Rails', true)
      end

      it 'forwards headers to the remote endpoint' do
        headers = { 'Some-Rails' => 'header' }
        ctx = double(request: double(env: {}, headers: double(to_h: headers)))
        assert_headers(headers, ctx)
      end

      it 'still sends the JSONAPI Content-Type header' do
        headers = { 'Content-Type' => 'application/vnd.api+json' }
        ctx = double(request: double(env: {}, headers: double(to_h: headers)))
        assert_headers(headers, ctx)
      end

      it 'can still override headers' do
        klass.class_eval do
          def request_headers
            { 'Some-Foo' => 'bar' }
          end
        end
        headers = { 'Some-Foo' => 'bar' }
        ctx = double(request: double(env: {}, headers: double(to_h: headers)))
        assert_headers(headers, ctx)
      end
    end

    context 'when passed sorts' do
      before do
        params[:sort] = '-first_name,last_name'
      end

      it 'queries correctly' do
        assert_params('sort=-first_name,last_name')
      end
    end

    context 'when passed filters' do
      before do
        params[:filter] = { first_name: { suffix: 'foo' }, age: { gt: 1 } }
      end

      it 'queries correctly' do
        assert_params('filter[age][gt]=1&filter[first_name][suffix]=foo')
      end
    end

    context 'when passed pagination' do
      before do
        params[:page] = { size: 10, number: 2 }
      end

      it 'queries correctly' do
        assert_params('page[number]=2&page[size]=10')
      end
    end

    context 'when passed fields' do
      before do
        params[:fields] = { employees: 'first_name,age' }
      end

      it 'queries correctly' do
        assert_params('fields[employees]=first_name,age')
      end
    end

    context 'when passed extra fields' do
      before do
        params[:extra_fields] = { employees: 'foo,bar' }
      end

      it 'queries correctly' do
        assert_params('extra_fields[employees]=foo,bar')
      end
    end

    context 'when passed statistic' do
      before do
        params[:stats] = { total: 'count' }
      end

      it 'queries correctly' do
        assert_params('stats[total]=count')
      end
    end

    context 'when passed includes' do
      before do
        params[:include] = 'positions.department,teams'
      end

      context 'and the association is defined locally' do
        let(:position_resource) do
          Class.new(PORO::PositionResource) do
            self.model = PORO::Position
          end
        end

        before do
          allow(PORO::PositionResource).to receive(:_all) { [] }
          klass.has_many :positions, resource: position_resource
        end

        it 'does not pass to the remote api' do
          assert_params('include=teams')
        end

        context 'but the local association is a remote resource with the same remote_base_url' do
          before do
            klass.class_eval do
              self.remote_base_url = 'http://foo.com/api/v1'
              self.remote = '/employees'
            end

            position_resource.class_eval do
              self.remote_base_url = 'http://foo.com/api/v1'
              self.remote = '/positions'
            end
          end

          it 'passes the include to the remote, and does not query locally' do
            expect(position_resource).to_not receive(:all)
            expect(position_resource).to_not receive(:_all)
            assert_params('include=positions.department,teams')
          end
        end
      end

      context 'and the association is NOT defined locally' do
        before do
          response[:data][0][:relationships] = {
            positions: {
              data: [{ id: '456', type: 'positions' }]
            }
          }
          response[:included] = [
            {
              id: '456',
              type: 'positions',
              attributes: { title: 'foo' },
              relationships: {
                department: { data: { id: '789', type: 'departments' } }
              }
            },
            {
              id: '789',
              type: 'departments',
              attributes: { name: 'Safety' }
            }
          ]
        end

        it 'is passed to the remote API' do
          assert_params('include=positions.department,teams')
        end

        it 'assigns associated models as relationships' do
          data = get_data
          expect(data[0].positions[0].department.name).to eq('Safety')
        end

        it 'serializes associated models in the response' do
          json = JSON.parse(query.to_jsonapi).deep_symbolize_keys
          expect(json[:data][0][:relationships]).to eq({
            positions: { data: [{ type: 'positions', id: '456' }]  }
          })
          expect(json[:included]).to eq(response[:included])
        end

        context 'and there is a nested sort' do
          before do
            params[:sort] = '-positions.department.name'
          end

          it 'is passed to the remote API' do
            assert_params('include=positions.department,teams&sort=-positions.department.name')
          end
        end

        context 'and there is nested pagination' do
          before do
            params[:page] = { :'positions.size' => 5, :'positions.number' => 2 }
          end

          it 'is passed to the remote API' do
            assert_params('include=positions.department,teams&page[positions.number]=2&page[positions.size]=5')
          end
        end

        context 'and there are nested filters' do
          before do
            params[:filter] = { :'positions.title' => { suffix: 'a' } }
          end

          it 'is passed to the remote API' do
            assert_params('filter[positions.title][suffix]=a&include=positions.department,teams')
          end
        end

        context 'and there are nested fields' do
          before do
            params[:fields] = { positions: 'foo,bar' }
          end

          it 'is passed to the remote API' do
            assert_params('fields[positions]=foo,bar&include=positions.department,teams')
          end
        end

        context 'and there are nested extra fields' do
          before do
            params[:extra_fields] = { positions: 'foo,bar' }
          end

          it 'is passed to the remote API' do
            assert_params('extra_fields[positions]=foo,bar&include=positions.department,teams')
          end
        end

        context 'and there is a nested statistic' do
          before do
            params[:stats] = { total: 'count' }
          end

          it 'is passed to the remote API' do
            assert_params('include=positions.department,teams&stats[total]=count')
          end
        end
      end
    end
  end

  context 'when the remote resource has a base scope' do
    before do
      klass.class_eval do
        def base_scope
          { sort: '-id' }
        end
      end
    end

    it 'is honored' do
      assert_params('sort=-id')
    end
  end

  context 'when inferring remote resource via sideload' do
    let(:klass) do
      Class.new(PORO::EmployeeResource) do
        self.model = PORO::Employee
      end
    end

    let(:response) do
      {
        data: [
          {
            id: '123',
            type: 'positions',
            attributes: {
              title: 'My Title',
              employee_id: 1
            }
          }
        ]
      }
    end

    before do
      PORO::Employee.create(first_name: 'Jane')
      klass.has_many :positions, remote: 'http://foo.com/api/v1/positions'
    end

    it 'creates an anonymous resource class' do
      expect(klass.sideloads[:positions].resource).to be_a(Graphiti::Resource)
    end

    it 'queries correctly' do
      url = 'http://foo.com/api/v1/positions?filter[employee_id]=1'
      expect(Faraday).to receive(:get).with(url, anything, anything)
      klass.all(include: 'positions').data
    end

    it 'works' do
      employees = klass.all(include: 'positions').data
      positions = employees[0].positions
      expect(positions.length).to eq(1)
      expect(positions[0].id).to eq('123')
      expect(positions[0]._type).to eq('positions')
      expect(positions[0].title).to eq('My Title')
      expect(positions[0].employee_id).to eq(1)
    end

    context 'and manually altering params' do
      before do
        klass.has_many :positions, remote: 'http://foo.com/api/v1/positions' do
          params do |hash|
            hash[:sort] = '-foo'
            hash[:page] = { size: 2 }
            hash[:fields] = { positions: [:title, :active] }
            hash[:filter][:employee_id] = 99999
          end
        end
      end

      it 'honors the param manipulation' do
        url = 'http://foo.com/api/v1/positions?fields[positions]=title,active&filter[employee_id]=99999&page[size]=2&sort=-foo'
        expect(Faraday).to receive(:get)
          .with(url, anything, anything)
        klass.all(include: 'positions').data
      end
    end
  end

  context 'when performing write operating' do
    context 'when creating' do
      it 'raises error' do
        expect {
          klass.build(data: { type: 'employees' }).save
        }.to raise_error(Graphiti::Errors::RemoteWrite, /not supported/)
      end
    end

    context 'when updating' do
      it 'raises error' do
        expect {
          klass.find(id: 1, data: { type: 'employees' }).update_attributes
        }.to raise_error(Graphiti::Errors::RemoteWrite, /not supported/)
      end
    end

    context 'when destroying' do
      it 'raises error' do
        expect {
          klass.find(id: 1).destroy
        }.to raise_error(Graphiti::Errors::RemoteWrite, /not supported/)
      end
    end
  end
end
