#! /usr/bin/env python
# cython: language_level=3
# distutils: language=c++

""" Parad1se L0st """

import asyncio
import os
from pathlib              import Path
from types                import *
from typing               import Callable
from typing               import List
from typing               import Tuple
from typing               import ParamSpec
from typing               import Optional
from typing               import *

from aiofiles.tempfile    import NamedTemporaryFile
import dotenv
from fastapi              import FastAPI
from fastapi              import File
from fastapi              import UploadFile
from fastapi              import Response
from fastapi              import status
from pymetasploit3.msfrpc import ConsoleManager
from pymetasploit3.msfrpc import MsfConsole
from pymetasploit3.msfrpc import MsfRpcClient
from pymetasploit3.msfrpc import MsfRpcMethod
from structlog            import get_logger

from iarest.main          import start_server

logger = get_logger()

async def db_connect(console:MsfConsole, dbconnect:str)->None:
	logger.debug('dbconnect: %s', dbconnect)
	connect_fmt:str = 'db_connect {dbconnect}'
	connect_cmd:str = connect_fmt.format(dbconnect=dbconnect)
	await _execute(console, connect_cmd)

def is_busy(out:Dict[str,Any])->bool:
	return out['busy']

async def _clear(console:MsfConsole)->str:
	out:str           = ''
	while True:
		_out:Dict[str,Any] = console.read()
		await logger.adebug('out: %s', _out)
		out      += _out['data']
		if (not is_busy(_out)):
			break
		asyncio.sleep(1)
	return out

async def _execute(console:MsfConsole, cmd:str,)->str:
	await logger.adebug("executing: %s", cmd)
	await _clear(console) # clear any cruft
	console.write(cmd)    # send to msfrpcd

	out           :str           = ''
	while True:
		_chunk:Dict[str,str] = console.read()#['data']
		await logger.adebug('chunk: %s', _chunk)
		chunk :str           = _chunk['data']
		out                 += chunk
		if (not is_busy(_chunk)):
			break
	return out

def get_client(user:str, passwd:str, msfrpcd:str)->MsfRpcClient:
	logger.info ('user      : %s', user)
	logger.debug('passwd    : %s', passwd)
	logger.info ('msfrpcd   : %s', msfrpcd)
	return MsfRpcClient(passwd, server=msfrpcd,  ssl=True) # user is not used

def raise_error(result:Union[List,Set,Dict,Tuple],msfrpcd:str)->None:
	""" https://stackoverflow.com/questions/9269902/is-there-a-way-to-create-subclasses-on-the-fly """
	assert isinstance(result,Dict)

	if ('error' not in result): # nothing to raise
		return

	assert ('error_class' in result)
	error_class  :Optional[str]   = result.get('error_class')
	logger.debug('error_class (%s): %s', type(error_class), error_class)
	assert error_class

	assert ('error_message' in result)
	error_message:Optional[str]   = result.get('error_message')
	logger.debug('error_message: %s', error_message)
	assert error_message

	if ('Invalid hostname:' in error_message):
		error_message        += f'({msfrpcd})'

	dyncls       :Type[Exception] = type(error_class, (Exception,), {})
	logger.debug('dynamic class (%s): %s', type(dyncls), dyncls)
	assert dyncls
	raise dyncls(error_message)

def _get_console(client:MsfRpcClient,msfrpcd:str, sanity_check:bool=True)->Optional[str]:
	if (not sanity_check):
		return None

	result:Union[List,Set,Dict,Tuple] = client.call(MsfRpcMethod.ConsoleCreate)
	logger.debug('result: %s', result)
	raise_error(result=result,msfrpcd=msfrpcd)

	assert ('id' in result)
	cid   :Optional[str]              = result.get('id')
	return cid

def get_console(client:MsfRpcClient, msfrpcd:str)->MsfConsole:
	cid:Optional[str]  = _get_console(client=client, msfrpcd=msfrpcd)
	mgr:ConsoleManager = client.consoles
	return mgr.console(cid=cid)

async def db_import(console:MsfConsole, file:NamedTemporaryFile,)->str:
	import_fmt:str     = 'db_import {dbimport}'
	import_cmd:str     = import_fmt.format(dbimport=file.name)
	return await _execute(console=console, cmd=import_cmd,)

def get_app(
	console  :MsfConsole,
	dbconnect:str,
	importdir:Path,
)->FastAPI:

	app                       :FastAPI = FastAPI()

	@app.on_event("startup")
	async def startup_event()->None:
		await db_connect(console=console, dbconnect=dbconnect)

	@app.post("/")
	async def _db_import(file:UploadFile=File(...))->Response:

		contents          :bytes   = await file.read()            # TODO encode/decode ?
		async with NamedTemporaryFile('wb', dir=importdir,) as f: # `f` must be same volume as msf daemon !
			os.chmod(f.name, 0o0644)                          # make it readable by msf daemon
			await f.write(contents)
			#await f.seek(0)                                  #
			await f.flush()                                   # jic
			result    :str     = await db_import(console=console, file=f,)
		return Response(content=result, media_type='text/plain', status_code=status.HTTP_200_OK)

	return app

def _main_with_console(
	host     :str,
	port     :int,
	console  :MsfConsole,
	dbconnect:str,
	importdir:Path,
)->None:
	app:FastAPI = get_app(console=console, dbconnect=dbconnect, importdir=importdir,)
	start_server(app=app, host=host, port=port,)

def _main(
	host     :str,
	port     :int,
	user     :str,
	passwd   :str,
	msfrpcd  :str,
	dbconnect:str,
	importdir:Path,
)->None:
	client :MsfRpcClient = get_client(user=user, passwd=passwd, msfrpcd=msfrpcd)
	logger.info('client connected')

	console:MsfConsole   = get_console(client=client, msfrpcd=msfrpcd)
	logger.info('console allocated')
	try:
		_main_with_console(host=host, port=port, console=console, dbconnect=dbconnect, importdir=importdir,)
	finally:
		console.destroy()

def main()->None:
	dotenv.load_dotenv()

	host           :str             =     os.getenv('HOST',        '0.0.0.0')
	port           :int             = int(os.getenv('PORT',        '55552'))

	user           :str             =     os.getenv('MSFUSER',     'msf')
	passwd         :str             =     os.getenv('MSFPASSWORD', 'root')
	#msfrpcd        :str             =     os.getenv('MSFRPCD',     'msf.innovanon.com')
	msfrpcd        :str             =     os.getenv('MSFRPCD',     '192.168.2.249')
	logger.info('msf user  : %s', user,)
	logger.info('msfrpcd   : %s', msfrpcd,)

	dbhost         :str             =     os.getenv('PGHOST',      'db.innovanon.com')
	dbport         :int             = int(os.getenv('PGPORT',      '5432'))
	dbuser         :str             =     os.getenv('PGUSER',      'postgres')
	dbpassword     :str             =     os.getenv('PGPASSWORD',  'postgres')
	dbname         :str             =     os.getenv('DBNAME',      'msf')
	dbconnect      :str             = str(f'postgresql://{dbuser}:{dbpassword}@{dbhost}:{dbport}/{dbname}')
	logger.info('dbhost    : %s', dbhost,)
	logger.info('dbport    : %s', dbport,)
	logger.info('dbname    : %s', dbname,)

	importdir      :Path            = Path(os.getenv('IMPORTDIR',  '/tmp/import'))
	logger.info('import dir: %s', importdir,)
	assert importdir.is_dir(), importdir.resolve()

	#_main(
	#	host     =host,
	#	port     =port,
	#	user     =user,
	#	passwd   =passwd,
	#	msfrcpd  =msfrpcd,
	#	dbconnect=dbconnect,
	#	importdir=importdir,)
	_main(host, port, user, passwd, msfrpcd, dbconnect, importdir,)

if __name__ == '__main__':
	main()

__author__:str = 'you.com' # NOQA
