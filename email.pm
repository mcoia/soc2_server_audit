#!/usr/bin/perl
# ---------------------------------------------------------------
# Copyright © 2013-2022 MOBIUS
# Blake Graham-Henderson blake@mobiusconsortium.org 2013-2022
# Scott Angel scottangel@mobiusconsoritum.org 2022
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# ---------------------------------------------------------------
package email;

use Email::MIME;
use Data::Dumper;

sub new
{
    my ( $class, $from, $emailRecipientArrayRef, $errorFlag, $successFlag,
        $confArrayRef )
      = @_;
    my @a;
    my @b;

    my $self = {
        fromEmailAddress    => $from,
        emailRecipientArray => \@{$emailRecipientArrayRef},
        notifyError         => $errorFlag,                    #true/false
        notifySuccess       => $successFlag,                  #true/false
        confArray           => \%{$confArrayRef},
        errorEmailList      => \@a,
        successEmailList    => \@b
    };

    my %varMap = (
        "successemaillist" => 'successEmailList',
        "erroremaillist"   => 'errorEmailList'
    );

    my %conf = %{ $self->{confArray} };

    while ( ( my $confKey, my $selfKey ) = each(%varMap) )
    {
        my @emailList = split( /,/, @conf{$confKey} );
        for my $y ( 0 .. $#emailList )
        {
            @emailList[$y] = trim( $self, @emailList[$y] );
        }
        $self->{$selfKey} = \@emailList;
    }

    bless $self, $class;
    return $self;
}

sub send    #subject, body
{
    my $self     = shift;
    my $subject  = shift;
    my $body     = shift;
    my @toEmails = @{ getFinalToList($self) };

    my $message = Email::MIME->create(
        header_str => [
            From    => $self->{fromEmailAddress},
            To      => [@toEmails],
            Subject => $subject
        ],
        attributes => {
            encoding => 'quoted-printable',
            charset  => 'ISO-8859-1',
        },
        body_str => "$body\n"
    );

    use Email::Sender::Simple qw(sendmail);

    sendmail($message);

}

sub sendWithAttachments    #subject, body, @attachments
{
    use Email::Stuffer;
    my $self          = shift;
    my $subject       = shift;
    my $body          = shift;
    my $attachmentRef = shift;
    my @attachments   = @{$attachmentRef};
    my @toEmails      = @{ getFinalToList($self) };

    foreach (@toEmails)
    {
        my $message = new Email::Stuffer;

        $message->to($_)->from( $self->{fromEmailAddress} )
          ->text_body("$body\n")->subject($subject);

        # attach the files
        $message->attach_file($_) foreach (@attachments);

        $message->send;
    }

}

sub getFinalToList
{
    my $self             = shift;
    my @additionalEmails = @{ $self->{emailRecipientArray} };
    my @success          = @{ $self->{successEmailList} };
    my @error            = @{ $self->{errorEmailList} };
    my @ret              = ();

    push( @ret, @error ) if ( $self->{'notifyError'} );

    push( @ret, @success ) if ( $self->{'notifySuccess'} );

    push( @ret, @additionalEmails ) if ( $#additionalEmails > -1 );

    # Dedupe
    @ret = @{ deDupeEmailArray( $self, \@ret ) };

    return \@ret;
}

sub deDupeEmailArray
{
    my $self          = shift;
    my $emailArrayRef = shift;
    my @emailArray    = @{$emailArrayRef};
    my %posTracker    = ();
    my %bareEmails    = ();
    my $pos           = 0;
    my @ret           = ();

    foreach (@emailArray)
    {
        my $thisEmail = $_;

# if the email address is expressed with a display name, strip it to just the email address
        $thisEmail =~ s/^[^<]*<([^>]*)>$/$1/g if ( $thisEmail =~ m/</ );

        # lowercase it
        $thisEmail = lc $thisEmail;

        # Trim the spaces
        $thisEmail = trim( $self, $thisEmail );

        $bareEmails{$thisEmail} = 1;
        if ( !$postTracker{$thisEmail} )
        {
            my @a = ();
            $postTracker{$thisEmail} = \@a;
        }
        push( @{ $postTracker{$thisEmail} }, $pos );
        $pos++;
    }
    while ( ( my $email, my $value ) = each(%bareEmails) )
    {
        my @a = @{ $postTracker{$email} };

        # just take the first occurance of the duplicate email
        push( @ret, @emailArray[ @a[0] ] );
    }

    return \@ret;
}

sub trim
{
    my $self   = shift;
    my $string = shift;
    $string =~ s/^\s+//;
    $string =~ s/\s+$//;
    return $string;
}

1;
