#! /usr/bin/env perl -w
use v5.14.0;
use lib 'lib/', '../lib/';
use Data::Dumper; ($Data::Dumper::Indent, $Data::Dumper::Sortkeys) = (1, 1);

use Business::IBAN::Util qw( numify_iban mod97 );

my %option = (
    file     => 'support/swift_iban_registry_0.txt',
    type     => 'db',
    revision => 93,
);
use Getopt::Long;
GetOptions(\%option, qw< file|f=s type|t=s revision|r=i >);

my %swift_fields = (
    'Name of country'                     => 'country',
    'IBAN prefix country code (ISO 3166)' => 'iso3166',
    'IBAN length'                         => 'iban_length',
    'IBAN structure'                      => 'pattern',
    'SEPA country'                        => 'is_sepa',
    'IBAN print format example'           => 'iban_print',
    'IBAN electronic format example'      => 'iban_electronic',
);
my $char2cc = {
    n => "[0-9]",
    a => "[A-Z]",
    c => "[A-Za-z0-9]",
    e => "[ ]",
};

my %db;
open(my $fh, '<', $option{file}) or die "Cannot open($option{file}): $!";
local $/ = "\015\012";
my $header = <$fh>;
while (my $line = <$fh>) {
    chomp($line);
    my ($item, @data) = split(/\t/, $line);
    next unless grep { $item eq $_ } keys %swift_fields;
    $db{ $swift_fields{ $item } } = \@data;
};
close($fh);

my %iban_db;
for (my $i = 0; $i < $#{ $db{iso3166} }; $i++) {
    $iban_db{ $db{iso3166}->[$i] } = { };
    for my $field (values %swift_fields) {
        next if $field eq 'iso3166';
        if ($field eq 'is_sepa') {
            $iban_db{ $db{iso3166}->[$i] }{$field} = $db{$field}->[$i] eq 'Yes' ? 1 : 0;
        }
        else {
            $iban_db{ $db{iso3166}->[$i] }{$field} = $db{$field}->[$i];
        }
        if ($field eq 'pattern') {
            my $par = $db{pattern}->[$i];
            my ($n, $fix);
            1 while
                $par =~ s{(\d+)\!([nace])}
                         {($n, $fix) = $1 > 99
                              ? ($1%10,int($1/10))
                              : ($1, ''); $fix . $char2cc->{$2}."{$n}"}eg;
            $iban_db{ $db{iso3166}->[$i] }{iban_structure} = $par;
        }
    }
}
write_code(\%iban_db, $option{type}, $option{revision});

sub write_code {
    my ($iban_db, $type, $revision) = @_;

    if ($type eq 'db') {
        my %db = map {
            ($_ => {
                country        => $iban_db->{$_}{country},
                iban_length    => $iban_db->{$_}{iban_length},
                iban_structure => $iban_db->{$_}{iban_structure},
                is_sepa        => $iban_db->{$_}{is_sepa},
                pattern        => $iban_db->{$_}{pattern},
            })
        } keys %$iban_db;

        printf <<'        EOH', $revision;
package Business::IBAN::Database;
use warnings;
use strict;

our $VERSION = 0.%03d; # Release of the document

use Business::IBAN::Util qw/numify_iban mod97/;
use Hash::Util 'lock_hash';

use Exporter 'import';
our @EXPORT = qw/iban_db numify_iban mod97/;

        EOH
        print "my ", Data::Dumper->Dump([\%db], [ "*iban_db"]);
        print <<'        EOF';

sub iban_db {
    lock_hash(%iban_db);
    return \%iban_db;
}

1;

=head1 NAME

Business::IBAN::Database - Simple database for checking IBANs

=head1 SYNOPSIS

    use Business::IBAN::Database;

    my $iso3166a2 = uc substr $iban, 0, 2;
    if (!exists iban_db->{$iso3166a2}) {
        die "Countrycode '$iso3166a2' not in IBAN.\n";
    }
    if (length($iban) != iban_db->{$iso3166a2}{iban_length}) {
        die "Invalid length for '$iban'.\n";
    }
    if ($iban !~ iban_db->{$iso3166a2}{iban_structure}) {
        die "Invalid pattern for '$iban'.\n";
    }
    if (mod97(numify_iban($iban)) != 1) {
        die "Invalid checksum for '$iban'.\n";
    }

=head1 DESCRIPTION

This module was generated from the F<swift_iban_registry_0.txt> document supplied by
SWIFT version 93 February 2023 (also F<swift_iban_registry_v93.pdf>).

All functions are exported by default.

=head2 iban_db()

Returns a reference to the "database" of known IBAN entities, keyed on the
two letter code for participating countries (See ISO 3166 alpha 2 codes).

=head1 COPYRIGHT

E<copy> MMXXIII - Abe Timmerman <abeltje@cpan.org>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

=cut
        EOF
    }
    elsif ($type eq 'test') {
        print <<'        EOH';
#! perl -I. -w
use t::Test::abeltje;

use Business::IBAN::Validator;

my $v = Business::IBAN::Validator->new();
isa_ok($v, 'Business::IBAN::Validator');

while (my $line = <DATA>) {
    chomp($line);
    my ($countrycode) = $line =~ m{^ (..) }x;
    my ($iban, $is_sepa) = split /,/, $line;
    lives_ok(
        sub { $v->validate($iban) },
        "Valid: $iban"
    );
    is($v->is_sepa($iban), $is_sepa, "$countrycode: Sepa $is_sepa");
}

abeltje_done_testing();

__DATA__
        EOH

        for my $country (sort {$a cmp $b} keys %$iban_db) {
            my $e_iban = $iban_db->{$country}{iban_electronic};
            (my $check = $e_iban) =~ s/^(..)../${1}00/;
            my $new_check = sprintf("%02u", (98 - mod97(numify_iban($check))));
            if (substr($e_iban, 2, 2) ne $new_check) {
                printf STDERR "# $country wrong example $e_iban ($new_check)\n";
                substr($iban_db->{$country}{iban_electronic}, 2, 2, $new_check);
                substr($iban_db->{$country}{iban_print}, 2, 2, $new_check);
            }
            print "$iban_db->{$country}{iban_electronic},$iban_db->{$country}{is_sepa}\n";
            print "$iban_db->{$country}{iban_print},$iban_db->{$country}{is_sepa}\n";
        }
    }
    else { die "unknown output type '$type'!!!"; }
}
