#!/usr/bin/perl
BEGIN { unshift( @INC, $1 ) if ( $0 =~ m/(.+)\// ); }
use strict;
use utf8;
use warnings;
use File::Basename;
use File::Spec;
use Digest::MD5 qw/md5_hex/;
use HTML::TreeBuilder;

use AMMS::Util;
use AMMS::AppFinder;
use AMMS::Downloader;
use AMMS::NewAppExtractor;
use AMMS::UpdatedAppExtractor;
use AMMS::DBHelper;
use Data::Dumper;

#require "zol_action.pl";

my $task_type = $ARGV[0];
my $task_id   = $ARGV[1];
my $conf_file = $ARGV[2];

my $market   = "sj.zol.com.cn";
my $url_base = "http://sj.zol.com.cn";

my $downloader = new AMMS::Downloader;

my %category_mapping = (
    "同步软件" => 1,
    "辅助软件" => 1,
    "系统管理" => 1,
    "中文输入" => 1,
    "红外蓝牙" => 1,
    "同步备份" => 1,
    "文件管理" => 1,
    "固件补丁" => 1,
    "影音播放" => 1,
    "网络相关" => 1,
    "安全助手" => 1,
    "导航地图" => 1,
    "应用工具" => 1,
    "桌面插件" => 1,
    "读书教育" => 2,
    "游戏娱乐" => 2,
    "即时通信" => 2,
    "通信辅助" => 3,
);

=pod
die "\nplease check config parameter\n" unless init_gloabl_variable($conf_file);

if ( $task_type eq 'find_app' )    ##find new android app
{
    my $AppFinder =
      new AMMS::AppFinder( 'MARKET' => $market, 'TASK_TYPE' => $task_type );
    $AppFinder->addHook( 'extract_page_list',       \&extract_page_list );
    $AppFinder->addHook( 'extract_app_from_feeder', \&extract_app_from_feeder );
    $AppFinder->run($task_id);
}
elsif ( $task_type eq 'new_app' )    ##download new app info and apk
{
    my $NewAppExtractor = new AMMS::NewAppExtractor(
        'MARKET'    => $market,
        'TASK_TYPE' => $task_type
    );
    $NewAppExtractor->addHook( 'extract_app_info', \&extract_app_info );
    $NewAppExtractor->run($task_id);
}
elsif ( $task_type eq 'update_app' )    ##download updated app info and apk
{
    my $UpdatedAppExtractor = new AMMS::UpdatedAppExtractor(
        'MARKET'    => $market,
        'TASK_TYPE' => $task_type
    );
    $UpdatedAppExtractor->addHook( 'extract_app_info', \&extract_app_info );
    $UpdatedAppExtractor->run($task_id);
}

exit;
=cut

sub extract_app_info {
    my $tree;
    my @node;
    my @tags;
    my @kids;
    my ( $worker, $hook, $webpage, $app_info ) = @_;

    eval {
        $tree = HTML::TreeBuilder->new;
        $tree->parse($webpage);

        #official category
        if ( $webpage =~ /软件类型(?:.*?)<a[^>]+>(.*?)<\/a>/s ) {
            $app_info->{official_category} = $1;
        }

        #trustgo_category_id
        if ( defined( $category_mapping{ $app_info->{official_category} } ) ) {
            $app_info->{trustgo_category_id} =
              $category_mapping{ $app_info->{official_category} };
        }

     #last_update app_name current_version total_install_times get from database
        my $dbh = new AMMS::DBHelper;
        my $app_extra_info =
          $dbh->get_extra_info( md5_hex( $app_info->{app_url} ) );
        if ( ref $app_extra_info eq "HASH" ) {
            $app_info->{last_update}     = $app_extra_info->{last_update};
            $app_info->{app_name}        = $app_extra_info->{app_name};
            $app_info->{current_version} = $app_extra_info->{current_version};
            $app_info->{total_install_times} =
              $app_extra_info->{total_install_times};
            $app_info->{size} = $app_extra_info->{size};
        }

        #descripton
        my $node = $tree->look_down( id => "info_more" );
        my $description_info = $node->as_text;
        $app_info->{description} =
          $description_info =~ s/\[.收起全部简介\]//;

        #icon
        my $main_class_first = $tree->look_down( class => "main" );
        my $icon_img = $main_class_first->find_by_tag_name("img");
        $app_info->{icon} = $icon_img->attr("src");

        #screens
        my $screen_pre = $main_class_first->find_by_tag_name("a");
        my $downloader = new AMMS::Downloader;
        my $res        = $downloader->download(
            File::Spec->catfile( $url_base, $screen_pre ) );
        if ($res) {
            my @screens;
            my $content = $res->content;
            my $tree_s  = HTML::TreeBuilder->new;
            $tree_s->parse($content);
            my $main = $tree->look_down( class => "main" );
            my @img_tags = $main->look_down( "_tag", "img" );
            foreach my $img (@img_tags) {
                my $img_src = $img->attr("src");
                $img_src =~ s/\/\d+x\d+//;
                push @screens, $img_src;
            }
            $tree_s->delete;
        }
        $tree->delete;
    };
    $app_info->{status} = 'success';
    $app_info->{status} = 'fail' if $@;
    return scalar %{$app_info};
}

sub extract_page_list {

    my ( $worker, $hook, $params, $pages ) = @_;

    my $webpage     = $params->{'web_page'};
    my $total_pages = 0;
    eval {
        my $per_page;
        if ( $webpage =~ /每页(\d+)款.*?共(\d+)页/s ) {
            $per_page    = $1;
            $total_pages = $2;
        }
        if ( $total_pages eq "1" ) {
            $pages = $1 if $params->{base_url} =~ /sub(\d+)/;
        }
        else {
            if ( $webpage =~ /page3.*?<a target="_self" href="(.*?)">/ ) {
                my $page_tmp = $1;
                my $page_base = $1 if $page_tmp =~ /(.*?_)\d+\.html/;
                for ( 1 .. $total_pages ) {
                    push @{$pages},
                      File::Spec->catfile( $url_base, $page_base, $_ );
                }
            }
        }
    };
    return 0 if $total_pages == 0;

    return 1;
}

sub extract_app_from_feeder {
    my $tree;
    my @node;

    my ( $worker, $hook, $params, $apps ) = @_;

    eval {
        my $webpage = $params->{'web_page'};
        $tree = HTML::TreeBuilder->new;
        my $dbh = new AMMS::DBHelper;
        $tree->no_expand_entities(1);
        $tree->parse($webpage);
        my @nodes =
          $tree->look_down( "_tag", "dl", "class", "list_dl clearfix" );
        for my $node (@nodes) {

            #app_url
            my $a_tag = $node->find_by_tag_name("a");
            my $app_url =
              File::Spec->catfile( $url_base, $a_tag->attr("href") );
            $apps->{$1} = $app_url
              if basename( $a_tag->attr("href") ) =~ /(\d+)/;
            my $dd_tag    = $node->find_by_tag_name("dd");
            my @span_tag  = $dd_tag->find_by_tag_name("span");
            my $name_info = $node->find_by_tag_name("a")->as_text;
            my ( $app_name, $app_version ) =
              ( $name_info =~ /(.*?)[vV]?((?:\d\.)+\d).*/ );

            if ( scalar @span_tag ) {

                #last_update
                $dbh->save_extra_info(
                    md5_hex($app_url),
                    {
                        last_update         => $span_tag[1]->as_text,
                        size                => kb_m( $span_tag[0]->as_text ),
                        total_install_times => $span_tag[2]->as_text,
                        app_name            => $app_name,
                        current_version     => $app_version,
                    }
                );
            }
        }
    };

    $apps = {} if $@;

    return 1;
}

sub kb_m {
    my $size = shift;

    # MB -> KB
    $size = $1 * 1024 if ( $size =~ s/([\d\.]+)(.*MB.*)/$1/i );
    $size = $1        if ( $size =~ s/([\d\.]+)(.*KB.*)/$1/i );

    # return byte
    return int( $size * 1024 );
}

