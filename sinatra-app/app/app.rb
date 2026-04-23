# frozen_string_literal: true
require 'sinatra/base'
require 'sequel'
require 'json'

DB = Sequel.connect(
  ENV['DATABASE_URL'] || "sqlite://#{File.expand_path('../db/app.sqlite3', __dir__)}"
)
DB.run("CREATE TABLE IF NOT EXISTS todos (id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL, completed BOOLEAN DEFAULT FALSE, created_at INTEGER)")

class App < Sinatra::Base

  set :public_folder, File.expand_path('../public', __dir__)
  set :views, File.expand_path('../views', __dir__)

  get '/' do
    content_type 'text/html; charset=utf-8'
    @title = 'Todo App'
    @todos = DB[:todos].order(:id).all
    erb :index, layout: :layout
  end

  post '/' do
    request.body.rewind
    body = JSON.parse(request.body.read)
    text = body['text']&.strip

    if text && !text.empty?
      DB[:todos].insert(text: text, completed: false, created_at: Time.now.to_i)
    end

    redirect '/'
  end

  post '/toggle/:id' do
    todo = DB[:todos].first(id: params['id'].to_i)
    if todo
      DB[:todos].where(id: params['id'].to_i).update(completed: !todo[:completed])
    end

    redirect '/'
  end

  post '/delete/:id' do
    DB[:todos].where(id: params['id'].to_i).delete
    redirect '/'
  end

  get '/api/todos' do
    content_type 'application/json'
    { todos: DB[:todos].order(:id).all }.to_json
  end

  get '/api/health' do
    content_type 'application/json'
    { status: 'ok', timestamp: Time.now.iso8601 }.to_json
  end
end
