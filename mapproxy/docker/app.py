# WSGI module for use with Apache mod_wsgi or gunicorn
# Vendored from https://github.com/mapproxy/mapproxy/blob/master/docker/app.py
# (MapProxy 7.0.0), plus MAPPROXY_CONFIG: the config file to load, default
# /mapproxy/config/mapproxy.yaml. docker-compose.4087.yaml sets it to
# mapproxy.4087.yaml; the Helm chart leaves it unset (see
# charts/rbt/templates/configmap-mapproxy.yaml).

from logging.config import fileConfig
import os

log_config = r'/mapproxy/config/logging.ini'

if os.path.isfile(log_config):
    print('Loading log config')
    fileConfig(log_config, {'here': os.path.dirname(__file__)})

multiapp_mapproxy = os.environ.get('MULTIAPP_MAPPROXY', False)

if multiapp_mapproxy:
    from mapproxy.multiapp import make_wsgi_app

    multiapp_allow_listings = os.environ.get('MULTIAPP_ALLOW_LISTINGS', False)

    print('Starting MapProxy in multi app mode')
    application = make_wsgi_app(r'/mapproxy/config/apps/', allow_listing=multiapp_allow_listings)
else:
    from mapproxy.wsgiapp import make_wsgi_app

    mapproxy_config = os.environ.get('MAPPROXY_CONFIG') or r'/mapproxy/config/mapproxy.yaml'

    print('Starting MapProxy in single app mode with ' + mapproxy_config)
    application = make_wsgi_app(mapproxy_config, reloader=True)
