package Blio::Node;
use 5.010;
use Moose;
use namespace::autoclean;
use MooseX::Types::Path::Class;
use Moose::Util::TypeConstraints;
use DateTime::Format::ISO8601;
use Encode;
use Markup::Unified;
use Blio::Image;
use XML::Atom::SimpleFeed;

class_type 'DateTime';
coerce 'DateTime' => from 'Int' => via {
    my $d = DateTime->from_epoch( epoch => $_ );
    $d->set_time_zone('local');
    return $d;
} => from 'Str' => via { DateTime::Format::ISO8601->parse_datetime($_) };

has 'base_dir' => ( is => 'ro', isa => 'Path::Class::Dir', required => 1 );
has 'source_file' =>
    ( is => 'ro', isa => 'Path::Class::File', required => 1, coerce => 1 );
has 'id' => (is => 'ro', isa=>'Str', required=>1, lazy_build=>1);
sub _build_id {
    my $self = shift;
    my $path = $self->source_file->relative($self->base_dir)->stringify;
    $path=~s/\.txt$//;
    return $path;
}
has 'url' => ( is => 'ro', isa => 'Str', lazy_build => 1 );
sub _build_url {
    my $self = shift;
    return $self->id.'.html';
}

has 'template' => (is=>'rw',isa=>'Str',required=>1,default=>'node.tt');
has 'title' => ( is => 'ro', isa => 'Str', required => 1 );
has 'date' => (
    is         => 'ro',
    isa        => 'DateTime',
    required   => 1,
    lazy_build => 1,
    coerce     => 1
);
sub _build_date {
    my $self = shift;
    my $stat = $self->source_file->stat;
    return $stat->mtime;
}

has 'language' => (is=>'ro', isa=>'Maybe[Str]');
has 'converter' => (is=>'ro', isa=>'Maybe[Str]');
has 'feed' => (is=>'ro',isa=>'Bool',default=>0);
has 'author' => (is=>'ro',isa=>'Str');

has 'raw_content'      => ( is => 'ro', isa => 'Str' );
has 'content' => ( is => 'rw', isa => 'Str', lazy_build=>1 );
sub _build_content {
    my $self = shift;
    my $converter = $self->converter;
    my $raw_content = $self->raw_content;
    return $raw_content unless $converter;
    
    given ($converter) {
        when ('html') { return $raw_content }
        when ([qw(textile markdown bbcode)]) {
            my $o = Markup::Unified->new();
            return $o->format($raw_content, 'textile')->formatted;
        }
        default {
            my $method = 'convert_'.$converter;
            if ($self->can($method)) {
                return $self->$method($raw_content);
            }
            else {
                return "<pre>No such converter: $converter</pre>".$raw_content;
            }
        }
    }
}
has 'tags'             => (
    is      => 'rw',
    isa     => 'ArrayRef',
    default => sub { [] },
    traits  => ['Array'] );
has 'images' => (
    is      => 'rw',
    isa     => 'ArrayRef[Blio::Image]',
    default => sub { [] },
    traits  => ['Array'],
    handles => {
        has_images   => 'count',
        add_image    => 'push',
    },
    );
has 'children' => (
    is      => 'rw',
    isa     => 'ArrayRef[Blio::Node]',
    default => sub { [] },
    traits  => ['Array'],
    handles => {
        has_children => 'count',
        add_child    => 'push',
    },

);
has 'parent' => ( is => 'rw', isa => 'Maybe[Blio::Node]', weak_ref => 1);
has 'stash' => (is=>'ro',isa=>'HashRef',default=>sub {{}});
has 'feed_url' => (is=>'ro',isa=>'Str',lazy_build=>1);
sub _build_feed_url {
    my $self = shift;
    return $self->id.'.xml';
}
sub new_from_file {
    my ( $class, $blio, $file ) = @_;
    my @lines = $file->slurp(
        chomp  => 1,
        iomode => '<:encoding(UTF-8)',
    );
    #warn $file;
    my ( $header, $raw_content ) = $class->parse(@lines);
    my $node = $class->new(
        base_dir    => $blio->source_dir,
        language    => $blio->language,
        converter   => $blio->converter,
        source_file => $file,
        %$header,
        raw_content => encode_utf8($raw_content),
    );

    # check and add images
    my $img_dir = $file->basename;
    $img_dir=~s/\.txt$//;
    $img_dir = $file->parent->subdir($img_dir.'_images');
    if (-d $img_dir) {
        while (my $image_file = $img_dir->next) {
            next unless $image_file =~ /\.jpe?g$/;
            my $img = Blio::Image->new(
                base_dir    => $blio->source_dir,
                source_file => $image_file,
            );
            $node->add_image($img);
        }
    }

    return $node;
}

sub parse {
    my ( $class, @lines ) = @_;
    my %header;
    while ( my $line = shift(@lines) ) {
        last if $line =~ /\^s+$/;
        last unless $line =~ /:/;
        my ( $key, $value ) = split( /\s*:\s*/, $line, 2 );
        $header{ lc($key) } = encode_utf8($value);
    }
    my $content = join( "\n", @lines );
    return \%header, $content;
}

sub write {
    my ($self, $blio) = @_;

    my $tt = $blio->tt;
    
    my $outfile = $blio->output_dir->file($self->url);
    $outfile->parent->mkpath unless (-d $outfile->parent);

    $tt->process($self->template,
        {
            node=>$self,
            blio=>$blio,
            base=>$self->relative_root,
        },
        ,$outfile->relative($blio->output_dir)->stringify
    ) || die $tt->error;

    my $utime = $self->date->epoch;
    utime($utime,$utime,$outfile->stringify);

    if ($self->has_images) {
        foreach my $img (@{$self->images}) {
            if ($blio->force || !-e $blio->output_dir->file($img->thumbnail)) {
                say "\timage ".$img->url unless $blio->quiet;
                $img->publish($blio);
                $img->make_thumbnail($blio);
            }
        }
    }

    $self->write_feed($blio) if $self->feed;
}

sub relative_root {
    my $self = shift;
    my $url = $self->url;
    my @level = $url=~m{/}g;
    
    return '' unless @level;
    
    return join('/',map { '..' } @level).'/';
}

sub possible_parent_url {
    my $self = shift;
    my $ppurl = $self->url;
    $ppurl =~ s{/\w+.html$}{.html};
    return $ppurl;
}

sub sorted_children {
    my $self = shift;
    my @sorted = 
        map { $_->[0] }
        sort { $b->[1] <=> $a->[1] }
        map { [$_ => $_->date->epoch] } @{$self->children};
    return \@sorted;
}

sub sorted_images {
    my $self = shift;
    my @sorted = 
        map { $_->[0] }
        sort { $a->[1] cmp $b->[1] }
        map { [$_ => $_->source_file->basename ] } @{$self->images};
    return \@sorted;
}

sub teaser {
    my ($self, $length) = @_;
    return unless $self->raw_content;
    $length ||= 200;
    my $teaser = substr($self->raw_content,0,$length);
    $teaser =~s/\s\S+$/ .../;
    return $teaser;
}

sub write_feed {
    my ($self, $blio) = @_;

    my $site_url = $blio->site_url;
    die "Cannot generate Atom Feed without site_url, use --site_url to set it" unless $site_url;
    $site_url .= '/' unless $site_url =~m{/$};

    my $children = $self->sorted_children;
    return unless @$children;
    my $feed = XML::Atom::SimpleFeed->new(
        title=>decode_utf8($self->title || 'no title'),
        author=>$blio->site_author || $0,
        link=>$site_url.$self->url,
        id=>$site_url.$self->url,
        updated=>$children->[0]->date->iso8601,
    );
    foreach my $child (@$children) {
        my %entry = (
            title=>decode_utf8($child->title || 'no title'),
            link=>$site_url.$child->url,
            id=>$child->url,
            updated=>$child->date->iso8601,
            category=>$child->parent->id,
            summary=>decode_utf8($child->teaser || ' '),
        );
        $entry{author} = $self->author if $self->author;
        $feed->add_entry( %entry );
    }
    my $feed_file = $blio->output_dir->file($self->feed_url);
    open(my $fh,'>:encoding(UTF-8)',$feed_file->stringify) || die "Cannot write to Atom feed file $feed_file: $!";
    $feed->print($fh);
    close $fh;
    
    my $utime = $children->[0]->date->epoch;
    utime($utime,$utime,$feed_file->stringify);
}

__PACKAGE__->meta->make_immutable;
1;