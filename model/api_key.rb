# frozen_string_literal: true

require_relative "../model"

require "bcrypt"

class ApiKey < Sequel::Model
  include ResourceMethods

  plugin :column_encryption do |enc|
    enc.column :key
  end

  def self.ubid_type
    UBID::TYPE_ETC
  end

  def self.create_with_id(owner_table:, owner_id:, used_for:)
    unless ["project", "inference_endpoint"].include?(owner_table)
      fail "Invalid owner_table: #{owner_table}"
    end

    key = SecureRandom.alphanumeric(32)
    super(owner_table: owner_table, owner_id: owner_id, key: key, key_hash: BCrypt::Password.create(key), used_for: used_for)
  end

  def rotate
    new_key = SecureRandom.alphanumeric(32)
    update(key: new_key, key_hash: BCrypt::Password.create(new_key), updated_at: Time.now)
  end
end
