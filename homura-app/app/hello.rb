# frozen_string_literal: true
# await: true
require 'sinatra/cloudflare_workers'
require 'sequel'
require 'sequel/adapters/d1'

class App < Sinatra::Base
  set :public_folder, File.expand_path('../public', __dir__)
  set :views, File.expand_path('../views', __dir__)

  helpers do
    def db
      @db ||= Sequel.connect(adapter: :d1, d1: env['cloudflare.DB'])
    end
  end

  get '/' do
    content_type 'text/html; charset=utf-8'
    @title = 'Todo App'
    @todos = db[:todos].order(:id).all.__await__
    erb :index, layout: :layout
  end

  post '/' do
    request.body.rewind
    body = JSON.parse(request.body.read)
    text = body['text']&.strip

    if text && !text.empty?
      db.execute("INSERT INTO todos (text, completed, created_at) VALUES (?, 0, ?)", arguments: [text, Time.now.to_i]).__await__
    end

    redirect '/'
  end

  post '/toggle/:id' do
    target_id = params['id'].to_i
    todo = db[:todos].first(id: target_id).__await__
    if todo
      new_val = todo[:completed].to_i == 0 ? 1 : 0
      db[:todos].where(id: target_id).update(completed: new_val).__await__
    end

    redirect '/'
  end

  post '/delete/:id' do
    target_id = params['id'].to_i
    db[:todos].where(id: target_id).delete.__await__
    redirect '/'
  end

  get '/api/todos' do
    content_type 'application/json'
    result = db[:todos].order(:id).all.__await__
    { todos: result }.to_json
  end

  get '/api/health' do
    content_type 'application/json'
    { status: 'ok', platform: 'cloudflare-workers', runtime: 'opal' }.to_json
  end

  get '/api/async-test' do
    p = `Promise.resolve("async-ok")`
    result = p.__await__
    `console.log('async-test awaited:', #{result})`
    result
  end

  get '/api/redirect-test' do
    redirect '/api/health'
  end

  get '/api/health' do
    content_type 'application/json'
    { status: 'ok', platform: 'cloudflare-workers', runtime: 'opal' }.to_json
  end

  get '/api/params-test/:id' do
    content_type 'application/json'
    { id: params['id'], id_class: params['id'].class.to_s }.to_json
  end
end

run App
