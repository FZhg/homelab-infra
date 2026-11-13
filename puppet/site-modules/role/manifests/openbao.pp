# Secrets server for the whole lab.
class role::openbao {
  include profile::base
  include profile::openbao
}
