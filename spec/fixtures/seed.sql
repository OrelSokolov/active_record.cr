-- Test fixture for active_record.cr specs (Rails-tutorial style).
-- Runs against a dedicated crails_ar_test database; datalake stays read-only.

CREATE TABLE IF NOT EXISTS posts (
  id           bigserial PRIMARY KEY,
  title        varchar(255) NOT NULL,
  body         text,
  views        bigint NOT NULL DEFAULT 0,
  score        float8,
  rating       numeric(3,2),
  published    boolean NOT NULL DEFAULT false,
  published_at timestamptz,
  tags         jsonb DEFAULT '[]'::jsonb,
  created_at   timestamp NOT NULL,
  updated_at   timestamp NOT NULL
);

CREATE TABLE IF NOT EXISTS comments (
  id         bigserial PRIMARY KEY,
  post_id    bigint NOT NULL REFERENCES posts(id),
  author     varchar(100),
  body       text NOT NULL,
  created_at timestamp NOT NULL,
  updated_at timestamp NOT NULL
);

TRUNCATE comments, posts RESTART IDENTITY CASCADE;

INSERT INTO posts (title, body, views, score, rating, published, published_at, tags, created_at, updated_at) VALUES
  ('Hello', 'first post body', 10, 1.5, 4.50, true,  '2026-01-05 10:00:00+03', '["news","hello"]', now(), now()),
  ('Second', NULL, 3, 2.25, 3.75, false, NULL, '[]', now(), now()),
  ('Third post', 'more text', 42, 0.5, NULL, true, '2026-02-01 08:30:00+03', '["misc"]', now(), now()),
  ('Fourth', 'unpublished draft', 0, NULL, NULL, false, NULL, '[]', now(), now()),
  ('Fifth', 'top viewed', 100, 4.75, 5.00, true, '2026-03-10 12:00:00+03', '["news","top"]', now(), now());

INSERT INTO comments (post_id, author, body, created_at, updated_at) VALUES
  (1, 'oleg', 'nice one', now(), now()),
  (1, 'anna', 'agreed', now(), now()),
  (1, NULL, 'anon comment', now(), now()),
  (2, 'anna', 'meh', now(), now()),
  (3, 'oleg', 'solid', now(), now()),
  (3, 'anna', 'wow', now(), now()),
  (3, NULL, 'same', now(), now()),
  (5, 'oleg', 'the best', now(), now());
