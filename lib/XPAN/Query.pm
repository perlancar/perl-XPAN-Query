package XPAN::Query;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;
use Log::Any '$log';

use Digest::MD5 qw(md5_hex);
use File::Slurp::Tiny qw(read_file write_file);
use PerlIO::gzip;
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

$SPEC{':package'} = {
    v => 1.1,
    summary => 'Query a {CPAN,MiniCPAN,DarkPAN} mirror',
};

our $CACHE_PERIOD = $ENV{XPAN_CACHE_PERIOD} // 86400;
our $URL          = $ENV{XPAN_URL} // ["/cpan", "http://www.cpan.org/"];

my %common_args = (
    url => {
        summary => "URL to repository, e.g. '/cpan' or 'http://host/cpan'",
        schema  => [str => default => $URL],
        description => <<'_',

If not specified, will default to `XPAN_URL` environment, or `$URL` variable
(which by default is set to `/cpan`).

_
    },
    cache_period => {
        schema => [int => default => $CACHE_PERIOD],
        cmdline_aliases => {
            nocache => {
                schema => [bool => {is=>1}],
                code   => sub { $_[0]{cache_period} = 0 },
            },
        },
        description => <<'_',

If you set this to 0 it means to force cache to expire. If you set this to -1 it
means to never expire the cache (always use the cache no matter how old it is).

_
    },
    detail => {
        summary => "If set to true, will return array of records instead of just ID's",
        schema  => 'bool',
    },
    temp_dir => {
        schema => 'str*',
    },
);

my %query_args = (
    query => {
        summary => 'Search query',
        schema => 'str*',
        cmdline_aliases => {q=>{}},
        pos => 0,
    },
);

sub _parse {

    my %args = @_;

    my $now = time();
    my $tmpdir = $args{temp_dir} // $ENV{TEMP} // $ENV{TMP} // "/tmp";
    my $cache_period = $args{cache_period} // $CACHE_PERIOD;
    state $ua = do { require LWP::UserAgent; LWP::UserAgent->new };
    my $url0 = $args{url} // $URL or die "Please supply url";
    my $filename = "02packages.details.txt";

    my $has_success_url;
    my $md5;
    my @gzst;
    my $gztarget;

  DOWNLOAD:
    for my $xpan_url0 (ref($url0) eq 'ARRAY' ? @$url0 : $url0) {

        # normalize for LWP, it won't accept /foo/bar, only file:/foo/bar
        my $xpan_url = URI->new($xpan_url0);
        unless ($xpan_url->scheme) { $xpan_url = URI->new("file:$xpan_url0") }

        $md5 = md5_hex("$xpan_url");

        # download file
        $gztarget = "$tmpdir/$filename.gz-$md5";
        @gzst = stat($gztarget);
        if (@gzst && ($cache_period < 0 || $gzst[9] >= $now-$cache_period)) {
            $log->tracef("Using cached download file %s", $gztarget);
            $has_success_url++;
            last DOWNLOAD;
        } else {
            my $url = "$xpan_url/modules/$filename.gz";
            $log->tracef("Downloading %s ...", $url);
            my $res = $ua->get($url);
            unless ($res->is_success) {
                $log->warnf("Can't get %s: %s", $url, $res->status_line);
                next DOWNLOAD;
            }
            $has_success_url++;
            $log->tracef("Writing %s ...", $gztarget);
            write_file($gztarget, $res->content);
            last DOWNLOAD;
        }
    }

    die "No mirrors available" unless $has_success_url;

    # extract and convert to SQLite database

    require DBI;
    my $sqlitetarget = "$tmpdir/$filename.sqlite-$md5";
    my @sqst = stat($sqlitetarget);
    my $dbh;
    if (@sqst && $sqst[9] >= $gzst[9]) {
        $log->tracef("Using cached SQLite file %s", $sqlitetarget);
        $dbh = DBI->connect("dbi:SQLite:dbname=$sqlitetarget", undef, undef,
                            {RaiseError=>1});
    } else {
        $log->tracef("Creating %s ...", $sqlitetarget);

        require IO::Compress::Gzip;

        open my($fh), "<:gzip", $gztarget
            or die "Can't open $gztarget (<:gzip): $!";

        unlink $sqlitetarget;
        $dbh = DBI->connect("dbi:SQLite:dbname=$sqlitetarget", undef, undef,
                            {RaiseError=>1});
        $dbh->do("CREATE TABLE author (id TEXT NOT NULL PRIMARY KEY)");
        $dbh->do("CREATE TABLE dist (name TEXT NOT NULL PRIMARY KEY, author TEXT, version TEXT, file TEXT)");
        $dbh->do("CREATE INDEX dist_author ON dist(author)");
        $dbh->do("CREATE TABLE package (name TEXT NOT NULL PRIMARY KEY, author TEXT, version TEXT, file TEXT, dist TEXT)");
        $dbh->do("CREATE INDEX package_author ON package(author)");
        $dbh->do("CREATE INDEX package_dist ON package(dist)");

        $dbh->begin_work;
        my $line = 0;
        while (<$fh>) {
            $line++;
            next unless /\S/;
            next if /^\S+:\s/;
            chomp;
            #say "D:$_";
            my ($pkg, $ver, $path) = split /\s+/, $_;
            $ver = undef if $ver eq 'undef';
            my ($author, $file) = $path =~ m!^./../(.+?)/(.+)!
                or die "Line $line: Invalid path $path";
            $dbh->do("INSERT OR IGNORE INTO author (id) VALUES (?)", {}, $author);
            my $dist = $file;
            # XXX should've extract metadata
            if ($dist =~ s/-v?(\d(?:\d*(\.[\d_][^.]*)*?)?).\D.+//) {
                #say "D:  dist=$dist, 1=$1";
                $dbh->do("INSERT OR IGNORE INTO dist (name, author, version, file) VALUES (?,?,?,?)", {},
                         $dist, $author, $1, $file);
                $dbh->do("INSERT OR IGNORE INTO package (name, author, version, file, dist) VALUES (?,?,?,?,?)", {},
                         $pkg, $author, $ver, $file, $dist);
            } else {
                $log->info("Line $line: Can't parse dist version from filename $file");
                $dbh->do("INSERT OR IGNORE INTO package (name, author, version, file) VALUES (?,?,?,?)", {},
                         $pkg, $author, $ver, $file);
                #next;
            }
        }
        $dbh->commit;
    }
    $dbh;
}

$SPEC{list_xpan_authors} = {
    v => 1.1,
    summary => 'List authors in {CPAN,MiniCPAN,DarkPAN} mirror',
    args => {
        %common_args,
        %query_args,
    },
    result_naked => 1,
    result => {
        description => <<'_',

By default will return an array of CPAN ID's. If you set `detail` to true, will
return array of records.

_
    },
    examples => [
        {
            summary => 'List all authors',
            argv    => [],
            test    => 0,
        },
        {
            summary => 'Find CPAN IDs which start with something',
            argv    => ['--url', 'http://www.cpan.org/', 'MICHAEL%'],
            result  => ['MICHAEL', 'MICHAELW'],
            test    => 0,
        },
    ],
};
sub list_xpan_authors {
    my %args = @_;
    my $detail = $args{detail};

    my $dbh = _parse(%args);
    my $q = $args{query} // ''; # sqlite is case-insensitive by default, yay
    $q = '%'.$q.'%' unless $q =~ /%/;

    my @bind;
    my @where;
    if (length($q)) {
        push @where, "(id LIKE ?)";
        push @bind, $q;
    }
    my $sql = "SELECT * FROM author".
        (@where ? " WHERE ".join(" AND ", @where) : "").
            " ORDER BY id";

    my @res;
    my $sth = $dbh->prepare($sql);
    $sth->execute(@bind);
    while (my $row = $sth->fetchrow_hashref) {
        push @res, $detail ? $row : $row->{id};
    }
    \@res;
}

$SPEC{list_xpan_packages} = {
    v => 1.1,
    summary => 'List packages in {CPAN,MiniCPAN,DarkPAN} mirror',
    args => {
        %common_args,
        %query_args,
        author => {
            summary => 'Filter by author',
            schema => 'str*',
            cmdline_aliases => {a=>{}},
        },
        dist => {
            summary => 'Filter by distribution',
            schema => 'str*',
            cmdline_aliases => {d=>{}},
        },
    },
    result_naked => 1,
    result => {
        description => <<'_',

By default will return an array of package names. If you set `detail` to true,
will return array of records.

_
    },
};
sub list_xpan_packages {
    my %args = @_;
    my $detail = $args{detail};

    my $dbh = _parse(%args);
    my $q = $args{query} // ''; # sqlite is case-insensitive by default, yay
    $q = '%'.$q.'%' unless $q =~ /%/;

    my @bind;
    my @where;
    if (length($q)) {
        push @where, "(name LIKE ?)";
        push @bind, $q;
    }
    if ($args{author}) {
        push @where, "(author=?)";
        push @bind, $args{author};
    }
    if ($args{dist}) {
        push @where, "(dist=?)";
        push @bind, $args{dist};
    }
    my $sql = "SELECT * FROM package".
        (@where ? " WHERE ".join(" AND ", @where) : "").
            " ORDER BY name";

    my @res;
    my $sth = $dbh->prepare($sql);
    $sth->execute(@bind);
    while (my $row = $sth->fetchrow_hashref) {
        push @res, $detail ? $row : $row->{name};
    }
    \@res;
}

$SPEC{list_xpan_modules} = $SPEC{list_xpan_packages};
sub list_xpan_modules {
    goto &list_xpan_packages;
}

$SPEC{list_xpan_dists} = {
    v => 1.1,
    summary => 'List distributions in {CPAN,MiniCPAN,DarkPAN} mirror',
    description => <<'_',

For simplicity and performance, this module parses distribution names from
tarball filenames mentioned in `02packages.details.txt.gz`, so it is not perfect
(some release tarballs, especially older ones, are not properly named). For more
proper way, one needs to read the metadata file (`*.meta`) for each
distribution.

_
    args => {
        %common_args,
        %query_args,
        author => {
            summary => 'Filter by author',
            schema => 'str*',
            cmdline_aliases => {a=>{}},
        },
    },
    result_naked => 1,
    result => {
        description => <<'_',

By default will return an array of distribution names. If you set `detail` to
true, will return array of records.

_
    },
    examples => [
        {
            summary => 'List all distributions',
            argv    => [],
            test    => 0,
        },
        {
            summary => 'Grep by distribution name, return detailed record',
            argv    => ['--url', '/cpan', 'data-table'],
            result  => [
                {
                    author  => "BIGJ",                          # ..{0}
                    file    => "Data-TableAutoSum-0.08.tar.gz", # ..{1}
                    name    => "Data-TableAutoSum",             # ..{2}
                    version => "0.08",                          # ..{3}
                }, # .[0]
                {
                    author  => "EZDB",                        # ..{0}
                    file    => "Data-Table-Excel-0.5.tar.gz", # ..{1}
                    name    => "Data-Table-Excel",            # ..{2}
                    version => "0.5",                         # ..{3}
                }, # .[1]
                {
                    author  => "EZDB",                   # ..{0}
                    file    => "Data-Table-1.70.tar.gz", # ..{1}
                    name    => "Data-Table",             # ..{2}
                    version => "1.70",                   # ..{3}
                }, # .[2]
            ],     # [2]
            test    => 0,
        },
        {
            summary   => 'Filter by author, return JSON',
            src       => 'list-xpan-dists --author perlancar --json',
            src_plang => 'bash',
            test      => 0,
        },
    ],
};
sub list_xpan_dists {
    my %args = @_;
    my $detail = $args{detail};

    my $dbh = _parse(%args);
    my $q = $args{query} // '';
    $q = '%'.$q.'%' unless $q =~ /%/;

    my @bind;
    my @where;
    if (length($q)) {
        push @where, "(name LIKE ?)";
        push @bind, $q;
    }
    if ($args{author}) {
        push @where, "(author=?)";
        push @bind, $args{author};
    }
    my $sql = "SELECT * FROM package".
        (@where ? " WHERE ".join(" AND ", @where) : "").
            " ORDER BY name";

    my @res;
    my $sth = $dbh->prepare($sql);
    $sth->execute(@bind);
    while (my $row = $sth->fetchrow_hashref) {
        push @res, $detail ? $row : $row->{name};
    }
    \@res;
}


1;
# ABSTRACT:

=head1 SYNOPSIS

 use XPAN::Query qw(
     list_xpan_packages
     list_xpan_modules
     list_xpan_dists
     list_xpan_authors
 );

 # the first query will download 02packages.details.txt.gz from a CPAN mirror
 # (the default is "/cpan" or "http://www.cpan.org/") and convert it to a SQLite
 # database, so it will take some time, e.g. several seconds for download (1.5MB
 # at the time of this writing, so a few seconds depending on your connection
 # speed) plus around 10-15s for conversion.

 my $res = list_xpan_authors("MICHAEL%"); # => ["MICHAEL", "MICHAELW"]

 # the subsequent queries will be instantaneous, unless you change mirror site
 # or 24 hours has passed, which is the default cache period.

 my list_xpan_modules(author=>"NEILB", detail=>1);


=head1 DESCRIPTION

XPAN is a term I coined for any repository (directory tree, be it on a local
filesystem or a remote network) that has structure like a CPAN mirror,
specifically having a C<modules/02packages.details.txt.gz> file. This includes a
normal CPAN mirror, a MiniCPAN, or a DarkPAN. Currently it I<excludes> BackPAN,
because it does not have C<02packages.details.txt.gz>, only
C<authors/id/C/CP/CPANID> directories.

With this module, you can query various things about the repository. This module
fetches C<02packages.details.txt.gz> and parses it (caching it locally for a
period of time).


=head1 VARIABLES

=head2 C<$XPAN::Query::CACHE_PERIOD> => int (default: 86400)

Set default cache period, in seconds.

=head2 C<$XPAN::Query::URL> => str (default: "/cpan")

Set default XPAN URL.


=head1 ENVIRONMENT

=head2 XPAN_CACHE_PERIOD => int

Can be used to preset C<$XPAN::Query::CACHE_PERIOD>.

=head2 XPAN_URL => str

Can be used to preset C<$XPAN::Query::URL>.


=head1 TODO


=head1 SEE ALSO

L<Parse::CPAN::Packages> is a more full-featured and full-fledged module to
parse C<02packages.details.txt.gz>. The downside is, startup and performance is
slower.

L<Parse::CPAN::Packages::Fast> is created as a more lightweight alternative to
Parse::CPAN::Packages.

L<PAUSE::Packages> also parses C<02packages.details.txt.gz>, it's just that the
interface is different.

L<PAUSE::Users> parses C<authors/00whois.xml>. XPAN::Query does not parse this
file, it is currently not generated/downloaded by CPAN::Mini, for example.

Tangentially related: L<BackPAN::Index>

=cut
