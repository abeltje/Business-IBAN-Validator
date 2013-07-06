#! /usr/bin/perl
use warnings;
use strict;
use autodie;
use Data::Dumper; $Data::Dumper::Indent = 1; $Data::Dumper::Sortkeys = 1;

use FindBin;
my %opt = (
    file => "$FindBin::Bin/IBAN_Registry.txt",
    type => 'db',
    debug => 0,
);
use Getopt::Long;
GetOptions(\%opt => qw/file|f=s type|t=s debug/);

my @db_fields = qw/
    name_of_country
    country_code_as_defined_in_iso_3166
    iban_length
    iban_iban_structure
    iban_iban_structure_re
    sepa_country
/;
my @tst_fields = qw/
    country_code_as_defined_in_iso_3166
    iban_print_format_example
    iban_electronic_format_example
    sepa_country
/;

my @fields = $opt{type} eq 'db' ? @db_fields : @tst_fields;
my %store_field = map +($_ => undef), @fields;

my $char2cc = {
    n => "[0-9]",
    a => "[A-Z]",
    c => "[A-Za-z0-9]",
    e => "[ ]",
};

my %data;
open my $fh, '<', $opt{file};
my $revision = '';
while (my $line = <$fh>) {
    ($revision) = $line =~ /Release\s+(\d+)/ if !$revision;
    my ($section, $country);
    if ($line =~ /^2\.(\d+)\s+(\w[\w ,.]+)$/) {
        $section = $1;
        $country = $2;
        print "$section => $country\n" if $opt{debug};
        $data{$section}{country} = $country;
        my $header = "";
        local $/ = "";
        while (my $par = <$fh>) {
            chomp($par);
            if ($header && exists $store_field{$header}) {
                print "$section: $header => $par\n" if $opt{debug};

                if (   $header eq "iban_iban_structure"
                    && $data{$section}{country_code_as_defined_in_iso_3166} eq 'KZ')
                {
                    $par = 'KZ2!n3!n13!c';
                }
                ($data{$section}{$header} = $par) =~ s/\s+/ /g;
                if ($header =~ /(?:_structure|bank_identifier_length)$/) {
                    my ($n, $fix);
                    1 while 
                        $par =~ s{(\d+)\!([nace])}
                                 {($n, $fix) = $1 > 99
                                     ? ($1%10,int($1/10))
                                     : ($1, ''); $fix . $char2cc->{$2}."{$n}"}eg;
                    ($data{$section}{"${header}_re"} = $par) =~ s/\s+/|/g;
                }
                $header = '';
            }
            else {
                ($header = lc($par)) =~ s/\s+/_/g;
                if ($header eq "iban_iban_structure_and_length") {
                    $header = "iban_iban_structure";
                }
                if ($header eq "iban_structure") {
                    $header = "iban_iban_structure";
                }
            }

            if (exists $data{$section}{sepa_country}) {
                $data{$section}{$_} ||= "" for @fields;
                last;
            }
        }
    }
}
close $fh;

if ($opt{type} eq 'db') {
    @fields = grep $_ !~ /(?:_structure|bank_identifier_length)$/, @fields;
    push @fields, 'iban_iban_structure';

    printf <<'    EOH', $revision;
package Business::IBAN::Database;
use warnings;
use strict;

our $VERSION = 0.%03d; # Release of the document

use Hash::Util 'lock_hash';
use Exporter 'import';
our @EXPORT = qw/iban_db numify_iban mod97/;

    EOH
    my %db;
    for my $id (sort { $a <=> $b } keys %data) {
        if ($data{$id}{name_of_country} eq 'France') {
            $data{$id}{country_code_as_defined_in_iso_3166} = 'FR';
        }
        if ($data{$id}{name_of_country} eq 'United Kingdom') {
            $data{$id}{country_code_as_defined_in_iso_3166} = 'GB';
        }
        $data{$id}{sepa_country} = $data{$id}{sepa_country} =~ /^Yes/ ? 1 : 0;
        my @iso3166s = split(
            /\s*,\s*/,
            $data{$id}{country_code_as_defined_in_iso_3166}
        );
        my @res = split /\|/, $data{$id}{iban_iban_structure_re};
        my @hss = split /\|/, $data{$id}{iban_iban_structure};
        my $df_re = $res[0];
        my $df_hs = $hss[0];
        for my $iso3166a2 (@iso3166s) {
            $db{$iso3166a2} = {
                country        => $data{$id}{name_of_country},
                iban_length    => $data{$id}{iban_length},
                iban_structure => shift(@res) || $df_re,
                pattern        => shift(@hss) || $df_hs,
                is_sepa        => $data{$id}{sepa_country},
            };
        }
    }
    print "my ", Data::Dumper->Dump([\%db], [ "*iban_db"]);
    print <<'    EOF';

sub iban_db {
    lock_hash(%iban_db);
    return \%iban_db;
}

my %lettermap = do {
    my $i = 10;
    map +($_ => $i++), 'A'..'Z';
};

sub numify_iban {
    my ($iban) = @_;

    my $to_check = substr($iban, 4) . substr($iban, 0, 4);
    $to_check =~ s/([A-Za-z])/$lettermap{uc($1)}/g;
    
    return $to_check;
}

sub mod97 {
    my ($number) = @_;

    # Max 9 digits, safe for 32bit INT
    my ($r, $l) = (0, 9);
    while ($number =~ s/^([0-9]{1,$l})//) {
        $r = $r . $1;
        $r %= 97;
        $l = 9 - length($r);
    }
    return $r;
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

This module was generated from the IBAN_Registry.pdf document supplied by
SWIFT version 45 April 2013.

All functions are exported by default.

=head2 iban_db()

Returns a reference to the "database" of known IBAN entities, keyed on the
two letter code for participating countries (See ISO 3166 alpha 2 codes).

=head2 numify_iban($iban)

Put the first four characters at the end of the string. Transform all letters
into numbers ([Aa] => 10 .. [Zz] => 35). This results in a string of digits
[0-9] that will be used as a number for the 97-check.

=head2 mod97($number)

Returns the remainder of division by 97.

=head1 STUFF

(c) MMXIII - Abe Timmerman <abeltje@cpan.org>

=cut
    EOF
}
else {
    print <<'    EOH';
#! perl -w
use strict;

use Test::More;
use Test::Exception;

use Business::IBAN::Validator;

my $v = Business::IBAN::Validator->new();
isa_ok($v, 'Business::IBAN::Validator');

while (my $line = <DATA>) {
    chomp($line);
    my ($iban, $is_sepa) = split /,/, $line;
    lives_ok(
        sub { $v->validate($iban) },
        "Valid: $iban"
    );
    is($v->is_sepa($iban), $is_sepa, "Sepa $is_sepa");
}

done_testing();

__DATA__
    EOH

    for my $k (sort {$a <=> $b} keys %data) {
        my $examples = $data{$k}{iban_electronic_format_example};
        $examples =~ s/ or / /;
        my @ibans = split " ", $examples;
        my $is_sepa = $data{$k}{sepa_country} =~ /^Yes/ ? 1 : 0;
        for my $iban (@ibans) {
            print "$iban,$is_sepa\n";
            (my $printable = $iban) =~ s/(\S{4})(?!$)/$1 /g;
            print "$printable,$is_sepa\n";
        }
    }
    print Dumper \%data if $opt{debug};
}
