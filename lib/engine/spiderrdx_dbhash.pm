use strict;
use warnings;

package spiderrdx_dbhash;
use Tie::Hash;
use dbutils qw($dbh);
use vars qw($dbh);
our @ISA = ("Tie::StdHash");

sub TIEHASH {
	my($self, $db_info) = @_;

	my $query = qq~
	DESC $db_info->{'table'};
	~;
	my $res = &dbutils::query('query' => $query, 'param' => []);
	$db_info->{'id'} = $res->[0]->[0];
	$db_info->{'key'} = $res->[1]->[0];
	$db_info->{'value'} = $res->[2]->[0];

	return bless $db_info, $self;
}

sub FETCH {
	my($self, $key) = @_;

	my $query = qq~
	SELECT $self->{'value'}
	FROM $self->{'table'}
	WHERE $self->{'key'} = ?
	~;
	my $res = &dbutils::query('query' => $query, 'param' => [$key]);

	return $res->[0]->[0];
}

sub STORE {
	my($self, $key, $value) = @_;

	unless ( &EXISTS($self, $key) ) {
		my $query = qq~
		INSERT INTO $self->{'table'}($self->{'key'}, $self->{'value'})
		VALUES(?, ?)
		~;
		my $res = &dbutils::query('query' => $query, 'param' => [$key, $value]);
	} else {
		my $query = qq~
		UPDATE $self->{'table'}
		SET $self->{'value'} = ?
		WHERE $self->{'key'} = ?
		~;
		my $res = &dbutils::query('query' => $query, 'param' => [$value, $key]);
	}
}

sub DELETE {
	my($self, $key) = @_;

	my $query = qq~
	DELETE FROM $self->{'table'}
	WHERE $self->{'key'} = ?
	~;
	my $res = &dbutils::query('query' => $query, 'param' => [$key]);
}

sub EXISTS {
	my($self, $key) = @_;

	my $query = qq~
	SELECT COUNT($self->{'key'})
	FROM $self->{'table'}
	WHERE $self->{'key'} = ?
	~;
	my $res = &dbutils::query('query' => $query, 'param' => [$key]);

	return $res->[0]->[0];
}

sub CLEAR {
	my $self = shift;

	my $query = qq~
	truncate $self->{'table'};
	~;
	&dbutils::query('query' => $query);
}

sub FIRSTKEY {
	my $self = shift;

	my $query = qq~
	SELECT $self->{'key'}
	FROM $self->{'table'}
	WHERE $self->{'id'} = 1;
	~;
	my $res = &dbutils::query('query' => $query);

	return $res->[0]->[0];
}

sub NEXTKEY {
	my($self, $prevkey) = @_;

	my $query = qq~
	SELECT alias1.$self->{'key'}
	FROM $self->{'table'} alias1, $self->{'table'} alias2
	WHERE alias2.$self->{'key'} LIKE ?
	AND alias1.$self->{'id'} = alias2.$self->{'id'}+1;
	~;
	my $res = &dbutils::query('query' => $query, 'param' => [$prevkey]);

	return $res->[0]->[0];
}

sub DESTROY {
	my $self = shift;
}

1;

#########################################
# CREATE TABLE spiderrdx_spider_visited_urls (
#	spiderrdx_svu_id BIGINT AUTO_INCREMENT PRIMARY KEY,
#	spiderrdx_svu_key BLOB,
#	spiderrdx_svu_value BLOB
#);
#########################################

#########################################
#CREATE TABLE spiderrdx_skipped_urls (
#	spiderrdx_sku_id BIGINT AUTO_INCREMENT PRIMARY KEY,
#	spiderrdx_sku_key BLOB,
#	spiderrdx_sku_value BLOB
#);
#########################################

#########################################
#CREATE TABLE spiderrdx_scripturl_counter (
#	spiderrdx_suc_id BIGINT AUTO_INCREMENT PRIMARY KEY,
#	spiderrdx_suc_key BLOB,
#	spiderrdx_suc_value BLOB
#);
#########################################

#########################################
#CREATE TABLE spiderrdx_skipurl_patterns (
#	spiderrdx_sup_id BIGINT AUTO_INCREMENT PRIMARY KEY,
#	spiderrdx_sup_key BLOB,
#	spiderrdx_sup_value BLOB
#);
#########################################

#########################################
#CREATE TABLE spiderrdx_bad_links (
#	spiderrdx_badlinks_id BIGINT AUTO_INCREMENT PRIMARY KEY,
#	spiderrdx_badlinks_key BLOB,
#	spiderrdx_badlinks_value BLOB
#);
#########################################

#########################################
#CREATE TABLE spiderrdx_validated (
#	spiderrdx_valid_id BIGINT AUTO_INCREMENT PRIMARY KEY,
#	spiderrdx_valid_key BLOB,
#	spiderrdx_valid_value BLOB
#);
#########################################

#create table spiderrdx_indexed_urls (
#	indexed_url_id integer unsigned primary key auto_increment, 
#	indexed_url varchar(255) not null,
#	indexed_url_md5 varchar(127),
#	indexed_url_content_md5 varchar(127)
#)

#create table spiderrdx_submitted_sites (
#	submitted_site_id integer unsigned primary key auto_increment,
#	submitted_site_url varchar(255) not null,
#	submitted_site_spider int(1) default 1,
#	submitted_site_index_page varchar(255),
#	submitted_site_cookies blob
#);

#create table spiderrdx_spider_rule_types (
#	spider_rule_type_id integer unsigned primary key auto_increment,
#	spider_rule_type_key varchar(63) not null,
#	spider_rule_type_desc varchar(127)
#);

#create table spiderrdx_spider_rules (
#	spider_rule_id integer unsigned primary key auto_increment,
#	spider_rule_submitted_site_id integer unsigned not null,
#	spider_rule_type_id integer unsigned not null,
#	spider_rule varchar(255) not null,
#	foreign key(spider_rule_type_id) references spiderrdx_spider_rule_types(spider_rule_type_id),
#	foreign key(spider_rule_submitted_site_id) references spiderrdx_submitted_sites(submitted_site_id)
#);
