#!/usr/bin/env ruby
# frozen_string_literal: true

Sequel::Model.db = Sequel.connect(
  ENV['DATABASE_URL'] || "sqlite://#{File.expand_path('../../db/app.sqlite3', __dir__)}"
)

class CreateUsers < Sequel::Migration
  def up
    create_table(:users) do
      primary_key :id
      String :name, null: false
    end
    insert(:users, name: 'Alice')
    insert(:users, name: 'Bob')
    insert(:users, name: 'Kazu')
  end

  def down
    drop_table(:users)
  end
end
