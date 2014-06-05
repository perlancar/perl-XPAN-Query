package XPAN::Query;

use 5.010001;
use strict;
use warnings;
use Log::Any '$log';

use Digest::MD5 qw(md5_hex);
use File::Slurp::Tiny qw(read_file write_file);
use LWP::UserAgent;
use Sereal qw(encode_sereal decode_sereal);
use String::ShellQuote;
use URI;

use Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(
                       list_xpan_packages
                       list_xpan_modules
                       list_xpan_dists
                       list_xpan_authors
               );

our %SPEC;
# VERSION
# DATE

my %common_args = (
    url => {
        summary => "URL to repository, e.g. '/cpan' or 'http://host/cpan'",
        schema  => 'str*',
        req => 1,
        pos => 0,
    },
    cache_period => {
        schema => [int => default => 86400],
        cmdline_aliases => {
            nocache => { code => sub { $_[0]{cache_period} = 0 } },
        },
    },
    temp_dir => {
        schema => 'str*',
    },
);

sub _parse {

    my %args = @_;

    my $now = time();

    my $xpan_url = $args{url} or die "Please supply url";
    # normalize for LWP, it won't accept /foo/bar, only file:/foo/bar
    $xpan_url = URI->new($xpan_url);
    unless ($xpan_url->scheme) { $xpan_url = URI->new("file:$args{url}") }

    my $tmpdir = $args{temp_dir} // $ENV{TEMP} // $ENV{TMP} // "/tmp";
    my $cache_period = $args{cache_period} // 86400;

    state $ua = LWP::UserAgent->new;
    my $filename = "02packages.details.txt";
    my $md5 = md5_hex("$xpan_url");

    # download file
    my $gztarget = "$tmpdir/$filename.gz-$md5";
    my @gzst = stat($gztarget);
    if (@gzst && $gzst[9] >= $now-$cache_period) {
        $log->tracef("Using cache file %s", $gztarget);
    } else {
        my $url = "$xpan_url/modules/$filename.gz";
        $log->tracef("Downloading %s ...", "$url");
        my $res = $ua->get($url);
        unless ($res->is_success) {
            die "Can't get $url: " . $res->status_line;
        }
        write_file($gztarget, $res->content);
    }

    # extract and process (XXX this is currently unix-specific)
    my $sertarget = "$tmpdir/$filename.sereal-$md5";
    my @serst = stat($sertarget);
    my $data;
    if (@serst && $serst[9] >= $gzst[9]) {
        $log->tracef("Using cache file %s", $sertarget);
        $data = decode_sereal(~~read_file($sertarget));
    } else {
        $log->trace("Parsing $filename.gz ...");
        my (%packages, %authors, %dists);
        open my($fh), "zcat ".shell_quote("$gztarget")."|";
        my $line = 0;
        while (<$fh>) {
            $line++;
            next unless /\S/;
            next if /^\S+:\s/;
            chomp;
            my ($pkg, $ver, $path) = split /\s+/, $_;
            $ver = undef if $ver eq 'undef';
            my ($author, $file) = $path =~ m!^./../(.+?)/(.+)!
                or die "Line $line: Invalid path $path";
            $authors{$author} = 1;
            $packages{$pkg} = $ver;
            my $dist = $file;
            # XXX should've extract metadata
            if ($dist =~ s/-v?(\d(?:\d*(\.[\d_][^.]*)*?)?).\D.+//) {
                $dists{$dist} = $1;

            } else {
                #warn "Line $line: Can't parse dist version from filename $file";
                #next;
            }
        }
        $data = {
            packages => \%packages,
            authors  => [sort keys %authors],
            dists    => \%dists,
        };
        write_file($sertarget, encode_sereal($data));
    }

    $data;
}

$SPEC{list_xpan_authors} = {
    v => 1.1,
    summary => 'List authors in {CPAN,MiniCPAN,DarkPAN} mirror',
    args => {
        %common_args,
    },
    result_naked => 1,
};
sub list_xpan_authors {
    my %args = @_;
    my $data = _parse(%args);
    $data->{authors};
}

$SPEC{list_xpan_packages} = {
    v => 1.1,
    summary => 'List packages in {CPAN,MiniCPAN,DarkPAN} mirror',
    args => {
        %common_args,
    },
    result_naked => 1,
};
sub list_xpan_packages {
    my %args = @_;
    my $data = _parse(%args);
    $data->{packages};
}

$SPEC{list_xpan_modules} = {
    v => 1.1,
    summary => 'List modules in {CPAN,MiniCPAN,DarkPAN} mirror',
    args => {
        %common_args,
    },
    result_naked => 1,
};
sub list_xpan_modules {
    my %args = @_;
    my $data = _parse(%args);
    $data->{packages};
}

$SPEC{list_xpan_dists} = {
    v => 1.1,
    summary => 'List distributions in {CPAN,MiniCPAN,DarkPAN} mirror',
    args => {
        %common_args,
    },
    result_naked => 1,
};
sub list_xpan_dists {
    my %args = @_;
    my $data = _parse(%args);
    $data->{dists};
}


1;
# ABSTRACT: Query a {CPAN,MiniCPAN,DarkPAN} mirror

=head1 SYNOPSIS

 use XPAN::Query qw(
     list_xpan_packages
     list_xpan_modules
     list_xpan_dists
     list_xpan_authors
 );
 my $res = list_ubuntu_releases(detail=>1);
 # raw data is in $Ubuntu::Releases::data;


=head1 DESCRIPTION

B<INITIAL RELEASE: no implementations yet>.

XPAN is a term I coined for any repository (directory tree, be it on a local
filesystem or a remote network) that has structure like a CPAN mirror,
specifically having a C<modules/02packages.details.txt.gz> file. This includes a
normal CPAN mirror, a MiniCPAN, or a DarkPAN. Currently it I<excludes> BackPAN,
because it does not have C<02packages.details.txt.gz>, only
C<authors/id/C/CP/CPANID> directories.

With this module, you can query various things about the repository. This module
fetches C<02packages.details.txt.gz> and parses it (caching it locally for a
period of time).


=head1 SEE ALSO

L<Parse::CPAN::Packages>

L<Parse::CPAN::Packages::Fast>

L<PAUSE::Packages>, L<PAUSE::Users>

Tangentially related: L<BackPAN::Index>

=cut
