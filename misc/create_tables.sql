create table if not exists users (
  id integer primary key autoincrement,
  authenticated_by text not null,
  remote_id integer not null,
  name text not null,
  profile_image_url text not null,
  created datetime default current_timestamp,
  updated datetime default current_timestamp,
  deleted datetime,
  UNIQUE(authenticated_by,remote_id)
);

create table if not exists keywords (
    id integer primary key autoincrement,
    name text not null,
    description text,
    value integer default 5,
    created datetime default current_timestamp,
    updated datetime default current_timestamp,
    deleted text,
    UNIQUE(name)
);

create table if not exists related_products (
    id integer primary key autoincrement,
    keyword_id integer not null,
    amazon_url  text not null,
    created datetime default current_timestamp,
    updated datetime default current_timestamp,
    deleted text
);

create table if not exists entries  (
    id integer primary key autoincrement,
    user_id integer not null,
    ishiki integer not null,
    html text,
    created datetime default current_timestamp,
    updated datetime default current_timestamp,
    deleted text
);

create table if not exists entry_keywords (
    id integer primary key autoincrement,
    entry_id integer not null,
    user_id integer not null,
    keyword_id integer not null,
    created datetime default current_timestamp,
    updated datetime default current_timestamp,
    deleted text,
    UNIQUE(entry_id,keyword_id)
);
