package Mojo::IRC::Server;
use strict;
$Mojo::IRC::Server::VERSION = "1.0.5";
use Encode;
use Encode::Locale;
use Carp;
use Parse::IRC;
use Mojo::IOLoop;
use POSIX ();
use List::Util qw(first);
use Fcntl ':flock';
use Mojo::IRC::Server::Base 'Mojo::EventEmitter';
use Mojo::IRC::Server::User;
use Mojo::IRC::Server::Channel;

has host => "0.0.0.0";
has port => 6667;
has network => "Mojo IRC NetWork";
has ioloop => sub { Mojo::IOLoop->singleton };
has parser => sub { Parse::IRC->new };
has servername => "mojo-irc-server";
has clienthost => 'hidden',
has create_time => sub{POSIX::strftime( '%Y/%m/%d %H:%M:%S', localtime() )};
has log_level => "info";
has log_path => undef;

has user => sub {[]};
has channel => sub {[]};

has log => sub{
    require Mojo::Log;
    no warnings 'redefine';
    *Mojo::Log::append = sub{
        my ($self, $msg) = @_;
        return unless my $handle = $self->handle;
        flock $handle, LOCK_EX;
        $handle->print(encode("console_out", decode("utf8",$msg))) or $_[0]->die("Can't write to log: $!");
        flock $handle, LOCK_UN;
    };
    Mojo::Log->new(path=>$_[0]->log_path,level=>$_[0]->log_level,format=>sub{
        my ($time, $level, @lines) = @_;
        my $title="";
        if(ref $lines[0] eq "HASH"){
            my $opt = shift @lines; 
            $time = $opt->{"time"} if defined $opt->{"time"};
            $title = (defined $opt->{"title"})?$opt->{title} . " ":"";
            $level  = $opt->{level} if defined $opt->{"level"};
        }
        @lines = split /\n/,join "",@lines;
        my $return = "";
        $time = POSIX::strftime('[%y/%m/%d %H:%M:%S]',localtime($time));
        for(@lines){
            $return .=
                $time
            .   " " 
            .   "[$level]" 
            . " " 
            . $title 
            . $_ 
            . "\n";
        }
        return $return;
    });
};

sub new_user{
    my $s = shift;
    my $user = $s->add_user(Mojo::IRC::Server::User->new(@_,_server=>$s));
    return $user if $user->is_virtual;
    $user->io->on(read=>sub{
        my($stream,$bytes) = @_;
        $bytes = $user->buffer . $bytes;
        my $pos = rindex($bytes,"\r\n");
        my $lines = substr($bytes,0,$pos);
        my $remains = substr($bytes,$pos+2);
        $user->buffer($remains);
        $stream->emit(line=>$_) for split /\r\n/,$lines;
    });
    $user->io->on(line=>sub{
        my($stream,$line)  = @_;
        my $msg = $s->parser->parse($line);
        $s->emit(user_msg=>$user,$msg);
        if($msg->{command} eq "PASS"){$user->emit(pass=>$msg)}
        elsif($msg->{command} eq "NICK"){$user->emit(nick=>$msg)}
        elsif($msg->{command} eq "USER"){$user->emit(user=>$msg)}
        elsif($msg->{command} eq "JOIN"){$user->emit(join=>$msg)}
        elsif($msg->{command} eq "PART"){$user->emit(part=>$msg)}
        elsif($msg->{command} eq "PING"){$user->emit(ping=>$msg)}
        elsif($msg->{command} eq "PONG"){$user->emit(pong=>$msg)}
        elsif($msg->{command} eq "MODE"){$user->emit(mode=>$msg)}
        elsif($msg->{command} eq "PRIVMSG"){$user->emit(privmsg=>$msg)}
        elsif($msg->{command} eq "QUIT"){$user->emit(quit=>$msg)}
        elsif($msg->{command} eq "WHO"){$user->emit(who=>$msg)}
        elsif($msg->{command} eq "WHOIS"){$user->emit(who=>$msg)}
        elsif($msg->{command} eq "LIST"){$user->emit(list=>$msg)}
        elsif($msg->{command} eq "TOPIC"){$user->emit(topic=>$msg)}
    });

    $user->io->on(error=>sub{
        my ($stream, $err) = @_;
        $s->emit(close_user=>$user);
        $s->debug("C[" .$user->name."] 连接错误: $err");
    });
    $user->io->on(close=>sub{
        my ($stream, $err) = @_;
        $s->emit(close_user=>$user);
    });
    $user->on(nick=>sub{my($user,$msg) = @_;my $nick = $msg->{params}[0];$user->set_nick($nick)});
    $user->on(user=>sub{my($user,$msg) = @_;
        if(defined $user->search_user(user=>$msg->{params}[0])){
            $user->send($user->serverident,"446",$user->nick,"该帐号已被使用");
             return;
        }
        $user->user($msg->{params}[0]);
        #$user->mode($msg->{params}[1]);
        $user->realname($msg->{params}[3]);
        $user->send($user->serverident,"001",$user->nick,"欢迎来到 Mojo IRC Network " . $user->ident);
        #$user->send($user->serverident,"002",$user->nick,"Your host is " . $user->servername . ", running version Mojo-IRC-Server-${Mojo::IRC::Server::VERSION}");
        #$user->send($user->serverident,"003",$user->nick,"This server has been started  " . $user->{_server}->create_time);
        #$user->send($user->serverident,"004",$user->nick,$user->servername .  "Mojo-IRC-Server-${Mojo::IRC::Server::VERSION} abBcCFioqrRswx abehiIklmMnoOPqQrRstvVz");
        #$user->send($user->serverident,"005",$user->nick,'RFC2812 IRCD=ngIRCd CHARSET=UTF-8 CASEMAPPING=ascii PREFIX=(qaohv)~&@%+ CHANTYPES=#&+ CHANMODES=beI,k,l,imMnOPQRstVz CHANLIMIT=#&+:10','are supported on this server");
        #$user->send($user->serverident,"251",$user->nick,$user->servername,"There are 0 users and 0 services on 1 servers");
        #$user->send($user->serverident,"254",$user->nick,$user->servername,0,"channels formed");
        #$user->send($user->serverident,"255",$user->nick,$user->servername,"I have 0 users, 0 services and 0 servers");
        #$user->send($user->serverident,"265",$user->nick,$user->servername,"");
        #$user->send($user->serverident,"250",$user->nick,$user->servername,"");
        #$user->send($user->serverident,"375",$user->nick,$user->servername,"- ".$user->servername." message of the day");
        #$user->send($user->serverident,"372",$user->nick,$user->servername,"- Welcome To Mojo IRC Server");
        #$user->send($user->serverident,"376",$user->nick,$user->servername,"End of MOTD command");
        #$user->send($user->serverident,"396",$user->nick,$user->clienthost,"是您当前显示的主机名称");
        
    });
    $user->on(join=>sub{my($user,$msg) = @_;
        my $channel_name = $msg->{params}[0];
        my $channel = $user->search_channel(name=>$channel_name);
        if(defined $channel){
            $user->join_channel($channel);
        }
        else{
            $channel = $user->new_channel(name=>$channel_name,id=>lc($channel_name));
            $user->join_channel($channel);
        }
    });
    $user->on(part=>sub{my($user,$msg) = @_;
        my $channel_name = $msg->{params}[0];
        my $part_info = $msg->{params}[1];
        my $channel = $user->search_channel(name=>$channel_name);
        return if not defined $channel;
        $user->part_channel($channel,$part_info);
    });
    $user->on(ping=>sub{my($user,$msg) = @_;
        my $servername = $msg->{params}[0];
        $user->send($user->servername,"PONG",$user->servername,$servername);
    });
    $user->on(pong=>sub{});
    $user->on(quit=>sub{my($user,$msg) = @_;
        my $quit_reason = $msg->{params}[0];
        $user->quit($quit_reason);
    });
    $user->on(privmsg=>sub{my($user,$msg) = @_;
        if(substr($msg->{params}[0],0,1) eq "#" ){
            my $channel_name = $msg->{params}[0];
            my $content = $msg->{params}[1];
            my $channel = $user->search_channel(name=>$channel_name);
            if(not defined $channel){$user->send($user->serverident,"403",$channel_name,"No such channel");return}
            $user->forward($user->ident,"PRIVMSG",$channel_name,$content);
            $s->info({level=>"IRC频道消息",title=>$user->nick ."|" .$channel->name.":"},$content);
        }
        else{
            my $nick = $msg->{params}[0];
            my $content = $msg->{params}[1];
            my $u = $user->search_user(nick=>$nick);
            if(defined $u){
                $u->send($user->ident,"PRIVMSG",$nick,$content);
                $s->info({level=>"IRC私信消息",title=>"[".$user->nick.".]->[$nick] :"},$content);
            }
            else{
                $user->send($user->serverident,"401",$user->nick,$nick,"No such nick");
            }
        }
    });
    $user->on(mode=>sub{my($user,$msg) = @_;
        if(substr($msg->{params}[0],0,1) eq "#" ){
            my $channel_name = $msg->{params}[0];
            my $channel_mode = $msg->{params}[1];
            my $channel = $user->search_channel(name=>$channel_name);
            if(not defined $channel){$user->send($user->serverident,"403",$channel_name,"No such channel");return}
            if(defined $channel_mode and $channel_mode eq "b"){
                $user->send($user->serverident,"368",$user->nick,$channel_name,"End of channel ban list");
            }   
            else{
                $user->send($user->serverident,"324",$user->nick,$channel_name,'+'.$channel->mode);
                $user->send($user->serverident,"329",$user->nick,$channel_name,$channel->ctime);
            }
        }
        else{
            my $nick = $msg->{params}[0];
            my $mode = $msg->{params}[1];
            if(defined $mode){$user->set_mode($mode)}
            else{$user->send($user->ident,"MODE",$user->nick,'+'.$user->mode)}
        }    
    });
    $user->on(who=>sub{my($user,$msg) = @_;
        my $channel_name = $msg->{params}[0];
        my $channel = $user->search_channel(name=>$channel_name);
        if(not defined $channel){$user->send($user->serverident,"403",$channel_name,"No such channel");return}
        $user->send($user->serverident,"352",$user->nick,$channel_name,$user->user,$user->host,$user->servername,$user->nick,"H","0 " . $user->realname);
        $user->send($user->serverident,"315",$user->nick,$channel_name,"End of WHO list");
    });
    $user->on(whois=>sub{my($user,$msg) = @_;});
    $user->on(list=>sub{my($user,$msg) = @_;
        for my $channel ($user->{_server}->channels){
            $user->send($user->serverident,"322",$user->nick,$channel->name,$channel->count(),$channel->topic);
        }
        $user->send($user->serverident,"323",$user->nick,"End of LIST");
    });
    $user->on(topic=>sub{my($user,$msg) = @_;
        my $channel_name = $msg->{params}[0];
        my $topic = $msg->{params}[1];
        my $channel = $user->search_channel(name=>$channel_name);
        if(not defined $channel){$user->send($user->serverident,"403",$channel_name,"No such channel");return}
        $channel->set_topic($user,$topic);
    });
    $user;
}
sub new_channel{
    my $s = shift;
    $s->add_channel(Mojo::IRC::Server::Channel->new(@_,_server=>$s));
}
sub add_channel{
    my $s = shift;
    my $channel = shift;
    my $is_cover = shift;
    my $c = $s->search_channel(id=>$channel->id);
    if(defined $c){if($is_cover){$s->info("频道 " . $c->name. " 已更新");$c=$channel;};return $c;}
    else{push @{$s->channel},$channel;$s->info("频道 ".$channel->name. " 已创建");return $channel;}

}
sub add_user{
    my $s = shift;
    my $user = shift;
    my $is_cover = shift;
    my $u = $s->search_user(id=>$user->id);
    if(defined $u){if($is_cover){$s->info("C[".$u->name. "]已更新");$u=$user;};return $u;}
    else{push @{$s->user},$user;$s->info("C[".$user->name. "]已加入");return $user;}    
}
sub remove_user{
    my $s = shift;
    my $user = shift;
    for(my $i=0;$i<@{$s->user};$i++){
        if($user->id eq $s->user->[$i]->id){
            splice @{$s->user},$i,1;
            if($user->is_virtual){
                $s->info("c[".$user->name."] 已被移除");
            }
            else{
                $s->info("C[".$user->name."] 已离开");
            }
            last;
        }
    }
}

sub remove_channel{
    my $s = shift;
    my $channel = shift;
    for(my $i=0;$i<@{$s->channel};$i++){
        if($channel->id eq $s->channel->[$i]->id){
            splice @{$s->channel},$i,1;
            $s->info("频道 ".$channel->name." 已删除");
            last;
        }
    }
}
sub users {
    my $s = shift;
    return @{$s->user};
}
sub channels{
    my $s = shift;
    return @{$s->channel};
}

sub search_user{
    my $s = shift;
    my %p = @_;
    return if 0 == grep {defined $p{$_}} keys %p;
    if(wantarray){
        return grep {my $c = $_;(first {$p{$_} ne $c->$_} grep {defined $p{$_}} keys %p) ? 0 : 1;} @{$s->user};
    }
    else{
        return first {my $c = $_;(first {$p{$_} ne $c->$_} grep {defined $p{$_}} keys %p) ? 0 : 1;} @{$s->user};
    }

}
sub search_channel{
    my $s = shift;
    my %p = @_;
    return if 0 == grep {defined $p{$_}} keys %p;
    if(wantarray){
        return grep {my $c = $_;(first {$_ eq "name"?(lc($p{$_}) ne lc($c->$_)):($p{$_} ne $c->{$_})} grep {defined $p{$_}} keys %p) ? 0 : 1;} @{$s->channel};
    }
    else{
        return first {my $c = $_;(first {$_ eq "name"?(lc($p{$_}) ne lc($c->{$_})):($p{$_} ne $c->{$_})} grep {defined $p{$_}} keys %p) ? 0 : 1;} @{$s->channel};
    }

}
sub timer{
    my $s = shift;
    $s->ioloop->timer(@_);
}
sub interval{
    my $s = shift;
    $s->ioloop->recurring(@_);
}
sub ident {
    return $_[0]->servername;
}
sub ready {
    my $s = shift;
    $s->ioloop->server({host=>$s->host,port=>$s->port}=>sub{
        my ($loop, $stream) = @_;
        $stream->timeout(0);
        my $id = join ":",(
            $stream->handle->sockhost,
            $stream->handle->sockport,
            $stream->handle->peerhost,
            $stream->handle->peerport
        );
        my $user = $s->new_user(
            id      =>  $id,
            name    =>  join(":",($stream->handle->peerhost,$stream->handle->peerport)),
            host    =>  $stream->handle->peerhost,
            port    =>  $stream->handle->peerport,
            io      =>  $stream,
        );
        
        $s->emit(new_user=>$user);
    });

    $s->on(new_user=>sub{
        my ($s,$user)=@_;
        $s->debug("C[".$user->name. "]已连接");
    });

    $s->on(user_msg=>sub{
        my ($s,$user,$msg)=@_;
        $s->debug("C[".$user->name."] $msg->{raw_line}");
    });

    $s->on(close_user=>sub{
        my ($s,$user,$msg)=@_;
        $s->remove_user($user);
    });

}
sub run{
    my $s = shift;
    $s->ready();
    $s->ioloop->start unless $s->ioloop->is_running;
} 
sub die{
    my $s = shift; 
    local $SIG{__DIE__} = sub{$s->log->fatal(@_);exit -1};
    Carp::confess(@_);
}
sub info{
    my $s = shift;
    $s->log->info(@_);
    $s;
}
sub warn{
    my $s = shift;
    $s->log->warn(@_);
    $s;
}
sub error{
    my $s = shift;
    $s->log->error(@_);
    $s;
}
sub fatal{
    my $s = shift;
    $s->log->fatal(@_);
    $s;
}
sub debug{
    my $s = shift;
    $s->log->debug(@_);
    $s;
}


1;
