-- Fixture migration: expand-only, with personal columns covered by ops/anonymize.
CREATE TABLE customers (
  id bigserial PRIMARY KEY,
  full_name text NOT NULL,
  email text NOT NULL UNIQUE,
  phone text,
  created_at timestamptz NOT NULL DEFAULT now()
);
