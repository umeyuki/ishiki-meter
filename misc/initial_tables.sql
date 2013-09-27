create table if not exists users (
  id integer primary key autoincrement,
  authenticated_by text not null,
  remote_id integer not null,
  name text not null,
  profile_image_url text not null,
  created text,
  updated text,
  deleted datetime,
  UNIQUE(authenticated_by,remote_id)
);

create table if not exists keywords (
    id integer primary key autoincrement,
    name text not null,
    initial_letter text not null,
    description text,
    value integer default 5,
    completed text,
    created text,
    updated text,
    deleted text,
    UNIQUE(name)
);

create table if not exists related_products (
    id integer primary key autoincrement,
    keyword_id integer not null,
    product_name text not null,
    contributer_name not null,
    publisher_name text,    
    image_url text not null,
    amazon_url  text not null,
    created text,
    updated text,
    deleted text
);

create table if not exists entries  (
    id integer primary key autoincrement,
    user_id integer not null,
    ishiki integer not null,

    created text,
    updated text,
    deleted text
);

create table if not exists entry_keywords (
    id integer primary key autoincrement,
    entry_id integer not null,
    user_id integer not null,
    keyword_id integer not null,
    created text,
    updated text,
    deleted text,
    UNIQUE(entry_id,keyword_id)
);
