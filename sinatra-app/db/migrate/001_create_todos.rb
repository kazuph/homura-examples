#!/usr/bin/env ruby
# frozen_string_literal: true

db = Sequel.connect(
  ENV['DATABASE_URL'] || "sqlite://#{File.expand_path('../../db/app.sqlite3', __dir__)}"
)

class CreateTodos < Sequel::Migration
  def up
    create_table(:todos) do
      primary_key :id
      String :text, null: false
      Boolean :completed, default: false
      Integer :created_at
    end
  end

  def down
    drop_table(:todos)
  end
end

CreateTodos.run(db)
