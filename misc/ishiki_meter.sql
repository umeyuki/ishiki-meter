create table keyword (
    id integer primary key autoincrement,
    name text not null,
    value integer default 5,
    created text not null,
    updated text not null,
    deleted text
);
create table persons (
    id integer primary key autoincrement,
    name text not null,
    amazon url not null,
    created text not null,
    updated text not null,
    deleted text
);