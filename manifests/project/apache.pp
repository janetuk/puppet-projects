# -- Resource type: project::apache
#
# Defines an apache project
define projects::project::apache (
  $vhosts        = {},
  $apache_user   = 'apache',
  $apache_common = {},
) {
  if !defined(Class['::apache']) {
    ensure_resource('class', '::apache', {
      default_vhost         => true,
      use_optional_includes => true
    })
    include ::apache::mod::proxy
    include ::apache::mod::alias
    include ::apache::mod::proxy_http
    include ::apache::mod::proxy_ajp
    class {'::apache::mod::authnz_ldap':
      verifyServerCert => false
    }

    if defined(Class['::selinux']) {
      ensure_resource('selinux::boolean', 'httpd_can_connect_ldap', {'ensure' =>  'on'})
    }


    # installing apache doesn't appear to pull in these deps.
    # Problem with the RPM or the puppetlabs/apache module?
    package { ['apr', 'apr-util']:
      ensure => present
    }
  }


  if $apache_common['php'] {
    ensure_resource('class', '::apache::mod::php', {})
    ensure_packages(['php-pdo', 'php-mysql', 'php-mbstring', 'php-snmp'])
  }


  file { "${::projects::basedir}/${title}/var/www":
    ensure  => directory,
    owner   => $apache_user,
    group   => $title,
    mode    => '0570',
    seltype => 'httpd_sys_content_t',
    require => File["${::projects::basedir}/${title}/var"],
  }

  file { "${::projects::basedir}/${title}/var/log/httpd":
    ensure  => directory,
    owner   => $apache_user,
    group   => $title,
    mode    => '0750',
    seltype => 'var_log_t',
    require => File["${::projects::basedir}/${title}/var/log"],
  }

  file { "/etc/logrotate.d/httpd-$title":
    ensure  => present,
    content => template('projects/apache/logrotate.erb'),
  }

  file { "${::projects::basedir}/${title}/etc/apache":
    ensure  => directory,
    owner   => $title,
    group   => $title,
    require => File["${::projects::basedir}/${title}/etc"],
  }

  file { "${::projects::basedir}/${title}/etc/apache/conf.d":
    ensure  => directory,
    owner   => $apache_user,
    group   => $title,
    mode    => '2770',
    seltype => 'httpd_config_t',
    require => File["${::projects::basedir}/${title}/etc/apache"],
  }

  file { "${::projects::basedir}/${title}/etc/ssl":
    ensure  => directory,
    owner   => $title,
    group   => $title,
    require => File["${::projects::basedir}/${title}/etc"],
  }

  file { [ "${::projects::basedir}/${title}/etc/ssl/private",
    "${::projects::basedir}/${title}/etc/ssl/certs",
    "${::projects::basedir}/${title}/etc/ssl/csrs",
    "${::projects::basedir}/${title}/etc/ssl/conf"] :
    ensure  => directory,
    owner   => $title,
    group   => $title,
    require => File["${::projects::basedir}/${title}/etc/ssl"],
  }

  sudo::conf { "${title}-apache":
    content => "%${title} ALL= (ALL) /sbin/apachectl"
  }

  create_resources('::projects::project::apache::vhost', $vhosts, {
    'projectname' => $title,
    'apache_user' => $apache_user
  })
}

# -- Resource type: project::apache::vhost
#
# Configures and projec apache vhost.
define projects::project::apache::vhost (
  $projectname = undef,
  $docroot = undef,
  $port = 80,
  $vhost_name = $title,
  $ssl = false,
  $php = false,
  $apache_user = 'apache',
  $altnames = []
) {

  concat::fragment { "${projectname} apache ${title} vhost":
    target  => "${::projects::basedir}/${projectname}/README",
    content => "Apache Virtualhost: ${vhost_name}
  hostname: ${vhost_name}
  port: ${port}
  SSL: ${ssl}
  PHP support: ${php}
  altnames: ${altnames}\n",
    order   => '10'
  }

  file { "${::projects::basedir}/${projectname}/etc/apache/conf.d/${title}":
    ensure  => directory,
    owner   => $apache_user,
    group   => $projectname,
    mode     => '2775',
    seltype => 'httpd_config_t',
    require => File["${::projects::basedir}/${projectname}/etc/apache/conf.d"],
  }

  ::apache::vhost { $title:
    servername          => $vhost_name,
    port                => $port,
    ssl                 => $ssl,
    docroot             => "${::projects::basedir}/${projectname}/var/www",
    logroot             => "${::projects::basedir}/${projectname}/var/log/httpd",
    additional_includes =>
      ["${::projects::basedir}/${projectname}/etc/apache/conf.d/*.conf",
      "${::projects::basedir}/${projectname}/etc/apache/conf.d/${title}/*.conf"],
    ssl_cert            =>
      "${::projects::basedir}/${projectname}/etc/ssl/certs/${vhost_name}.crt",
    ssl_key             =>
      "${::projects::basedir}/${projectname}/etc/ssl/private/${vhost_name}.key",
    serveraliases       => $altnames,
    # Use mod_remoteip for client IP if available:
    access_log_format   => '%a %l %u %t \"%r\" %>s %b \"%{Referer}i\" \"%{User-Agent}i\"',
  }

  if $ssl == true {
    $country= hiera('projects::ssl::country','GB')
    if (hiera('projects::ssl::state','') != '') {
      $state = hiera('projects::ssl::state')
    }
    if (hiera('projects::ssl::locality','') != '') {
      $locality = hiera('projects::ssl::locality')
    }
    $organization = hiera('projects::ssl::organization','ACME')
    if (hiera('projects::ssl::unit','') != '') {
      $unit = hiera('projects::ssl::unit',nil)
    }
    $commonname = $vhost_name
    if (hiera('projects::ssl::email','') != '') {
      $email = hiera('projects::ssl::email',nil)
    }
    file {"${::projects::basedir}/${projectname}/etc/ssl/conf/${vhost_name}.cnf":
      content => template('openssl/cert.cnf.erb'),
      require  => File["${::projects::basedir}/${projectname}/etc/ssl/conf"],

    }

    ssl_pkey { "${::projects::basedir}/${projectname}/etc/ssl/private/${vhost_name}.auto.key" :
      ensure   => present,
      require  => File["${::projects::basedir}/${projectname}/etc/ssl/private"],
    }

    x509_request { "${::projects::basedir}/${projectname}/etc/ssl/csrs/${vhost_name}.auto.csr" :
      ensure      => present,
      template    => "${::projects::basedir}/${projectname}/etc/ssl/conf/${vhost_name}.cnf",
      private_key => "${::projects::basedir}/${projectname}/etc/ssl/private/${vhost_name}.auto.key",
      require => [Ssl_pkey["${::projects::basedir}/${projectname}/etc/ssl/private/${vhost_name}.auto.key"],File["${::projects::basedir}/${projectname}/etc/ssl/conf/${vhost_name}.cnf"]],
    }

    x509_cert { "${::projects::basedir}/${projectname}/etc/ssl/certs/${vhost_name}.auto.crt":
      ensure      => present,
      template    => "${::projects::basedir}/${projectname}/etc/ssl/conf/${vhost_name}.cnf",
      private_key => "${::projects::basedir}/${projectname}/etc/ssl/private/${vhost_name}.auto.key",
      days        => 4536,
      require => [Ssl_pkey["${::projects::basedir}/${projectname}/etc/ssl/private/${vhost_name}.auto.key"],File["${::projects::basedir}/${projectname}/etc/ssl/conf/${vhost_name}.cnf"]],
    }

    exec { "deploy ${vhost_name}.key" :
      command => "/bin/cp ${::projects::basedir}/${projectname}/etc/ssl/private/${vhost_name}.auto.key ${::projects::basedir}/${projectname}/etc/ssl/private/${vhost_name}.key",
      onlyif  => "/bin/test ! -f ${::projects::basedir}/${projectname}/etc/ssl/private/${vhost_name}.key",
      require => Ssl_pkey["${::projects::basedir}/${projectname}/etc/ssl/private/${vhost_name}.auto.key"],
    }

    file { "${::projects::basedir}/${projectname}/etc/ssl/private/${vhost_name}.key":
      replace => 'no',
      seltype => 'cert_t',
      require => Exec["deploy ${vhost_name}.key"],
    }

    exec { "deploy ${vhost_name}.crt" :
      command => "/bin/cp ${::projects::basedir}/${projectname}/etc/ssl/certs/${vhost_name}.auto.crt ${::projects::basedir}/${projectname}/etc/ssl/certs/${vhost_name}.crt",
      onlyif  => "/bin/test ! -f ${::projects::basedir}/${projectname}/etc/ssl/certs/${vhost_name}.crt",
      require => X509_cert["${::projects::basedir}/${projectname}/etc/ssl/certs/${vhost_name}.auto.crt"],
    }

    file { "${::projects::basedir}/${projectname}/etc/ssl/certs/${vhost_name}.crt": 
      replace => 'no',
      seltype => 'cert_t',
      require => Exec["deploy ${vhost_name}.crt"],
    }
  }


  if !defined(Firewall["050 accept Apache ${port}"]) {
    firewall { "050 accept Apache ${port}":
      port   => $port,
      proto  => tcp,
      action => accept,
    }
  }

}
