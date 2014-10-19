{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
module Web.Spock.Simple
    ( -- * Spock's core
      spock, SpockM, SpockAction
    , spockT, SpockT, ActionT
    , spockApp
     -- * Defining routes
    , SpockRoute, (<#>)
     -- * Hooking routes
    , subcomponent
    , get, post, head, put, delete, patch, hookRoute, hookAny
    , Http.StdMethod (..)
     -- * Handeling requests
    , request, header, cookie, body, jsonBody, jsonBody', files, UploadedFile (..)
    , params, param, param'
     -- * Sending responses
    , setStatus, setHeader, redirect, jumpNext, setCookie, setCookie', bytes, lazyBytes
    , text, html, file, json, blaze
     -- * Adding and communicating with middleware
    , middleware, queryVault
      -- * Using Spock as middleware
    , spockMiddleware, middlewarePass, modifyVault
      -- * Database
    , PoolOrConn (..), ConnBuilder (..), PoolCfg (..)
      -- * Accessing Database and State
    , HasSpock (runQuery, getState), SpockConn, SpockState, SpockSession
      -- * Sessions
    , SessionCfg (..)
    , readSession, writeSession, modifySession, clearAllSessions
      -- * Basic HTTP-Auth
    , requireBasicAuth
      -- * Safe actions
    , SafeAction (..)
    , safeActionPath
      -- * Digestive Functors
    , runForm
      -- * Internals for extending Spock
    , getSpockHeart, runSpockIO, WebStateM, WebState
    )
where


import Web.Spock.Internal.CoreAction
import Web.Spock.Internal.Digestive
import Web.Spock.Internal.Monad
import Web.Spock.Internal.SessionManager
import Web.Spock.Internal.Types
import Web.Spock.Internal.Wrapper
import qualified Web.Spock.Internal.Wire as W
import qualified Web.Spock.Internal.Core as C

import Control.Applicative
import Control.Monad.Trans
import Data.Monoid
import Data.String
import Network.HTTP.Types.Method
import Prelude hiding (head)
import Web.Routing.TextRouting
import qualified Data.Text as T
import qualified Network.HTTP.Types as Http
import qualified Network.Wai as Wai
import qualified Network.Wai.Handler.Warp as Warp

type SpockM conn sess st a = SpockT (WebStateM conn sess st) a

newtype SpockT m a
    = SpockT { runSpockT :: C.SpockAllT (TextRouter (ActionT m) ()) m a
             } deriving (Monad, Functor, Applicative, MonadIO)

instance MonadTrans SpockT where
    lift = SpockT . lift

newtype SpockRoute
    = SpockRoute { _unSpockRoute :: T.Text }
    deriving (Eq, Ord, Show, Read, IsString)

-- | Run a spock application using the warp server, a given db storageLayer and an initial state.
-- Spock works with database libraries that already implement connection pooling and
-- with those that don't come with it out of the box. For more see the 'PoolOrConn' type.
spock :: Int -> SessionCfg sess -> PoolOrConn conn -> st -> SpockM conn sess st () -> IO ()
spock port sessCfg poolOrConn initSt spockAppl =
    spockAll TextRouter port sessCfg poolOrConn initSt (runSpockT spockAppl')
    where
      spockAppl' =
          do hookSafeActions
             spockAppl

-- | Run a raw spock application with custom underlying monad
spockT :: (MonadIO m)
       => Warp.Port
       -> (forall a. m a -> IO a)
       -> SpockT m ()
       -> IO ()
spockT port liftFun (SpockT app) =
    C.spockAllT TextRouter port liftFun app

-- | Convert a Spock-App to a wai-application
spockApp :: (MonadIO m) => (forall a. m a -> IO a) -> SpockT m () -> IO Wai.Application
spockApp liftFun (SpockT app) =
    W.buildApp TextRouter liftFun app

-- | Convert a Spock-App to a wai-middleware
spockMiddleware :: (MonadIO m) => (forall a. m a -> IO a) -> SpockT m () -> IO Wai.Middleware
spockMiddleware liftFun (SpockT app) =
    W.buildMiddleware TextRouter liftFun app

-- | Combine two route components safely
-- "/foo" <#> "/bar" ===> "/foo/bar"
-- "foo" <#> "bar" ===> "/foo/bar"
-- "foo <#> "/bar" ===> "/foo/bar"
(<#>) :: SpockRoute -> SpockRoute -> SpockRoute
(SpockRoute t) <#> (SpockRoute t') = SpockRoute $ combineRoute t t'

-- | Specify an action that will be run when the HTTP verb 'GET' and the given route match
get :: MonadIO m => SpockRoute -> ActionT m () -> SpockT m ()
get = hookRoute GET

-- | Specify an action that will be run when the HTTP verb 'POST' and the given route match
post :: MonadIO m => SpockRoute -> ActionT m () -> SpockT m ()
post = hookRoute POST

-- | Specify an action that will be run when the HTTP verb 'HEAD' and the given route match
head :: MonadIO m => SpockRoute -> ActionT m () -> SpockT m ()
head = hookRoute HEAD

-- | Specify an action that will be run when the HTTP verb 'PUT' and the given route match
put :: MonadIO m => SpockRoute -> ActionT m () -> SpockT m ()
put = hookRoute PUT

-- | Specify an action that will be run when the HTTP verb 'DELETE' and the given route match
delete :: MonadIO m => SpockRoute -> ActionT m () -> SpockT m ()
delete = hookRoute DELETE

-- | Specify an action that will be run when the HTTP verb 'PATCH' and the given route match
patch :: MonadIO m => SpockRoute -> ActionT m () -> SpockT m ()
patch = hookRoute PATCH

-- | Specify an action that will be run when a HTTP verb and the given route match
hookRoute :: Monad m => StdMethod -> SpockRoute -> ActionT m () -> SpockT m ()
hookRoute m (SpockRoute path) action = SpockT $ C.hookRoute m (TextRouterPath path) (TAction action)

-- | Specify an action that will be run when a HTTP verb matches but no defined route matches.
-- The full path is passed as an argument
hookAny :: Monad m => StdMethod -> ([T.Text] -> ActionT m ()) -> SpockT m ()
hookAny m action = SpockT $ C.hookAny m action

-- | Define a subcomponent. Usage example:
--
-- > subcomponent "/site" $
-- >   do get "/home" homeHandler
-- >      get "/misc/:param" $ -- ...
-- > subcomponent "/admin" $
-- >   do get "/home" adminHomeHandler
--
-- The request /site/home will be routed to homeHandler and the
-- request /admin/home will be routed to adminHomeHandler
subcomponent :: Monad m => SpockRoute -> SpockT m () -> SpockT m ()
subcomponent (SpockRoute p) (SpockT subapp) = SpockT $ C.subcomponent (TextRouterPath p) subapp

-- | Hook wai middleware into Spock
middleware :: Monad m => Wai.Middleware -> SpockT m ()
middleware = SpockT . C.middleware

-- | Write to the current session. Note that all data is stored on the server.
-- The user only reciedes a sessionId to be identified.
writeSession :: sess -> SpockAction conn sess st ()
writeSession d =
    do mgr <- getSessMgr
       (sm_writeSession mgr) d

-- | Modify the stored session
modifySession :: (sess -> sess) -> SpockAction conn sess st ()
modifySession f =
    do mgr <- getSessMgr
       (sm_modifySession mgr) f

-- | Read the stored session
readSession :: SpockAction conn sess st sess
readSession =
    do mgr <- getSessMgr
       sm_readSession mgr

-- | Globally delete all existing sessions. This is useful for example if you want
-- to require all users to relogin
clearAllSessions :: SpockAction conn sess st ()
clearAllSessions =
    do mgr <- getSessMgr
       sm_clearAllSessions mgr

-- | Wire up a safe action: Safe actions are actions that are protected from
-- csrf attacks. Here's a usage example:
--
-- > newtype DeleteUser = DeleteUser Int deriving (Hashable, Typeable, Eq)
-- >
-- > instance SafeAction Connection () () DeleteUser where
-- >    runSafeAction (DeleteUser i) =
-- >       do runQuery $ deleteUserFromDb i
-- >          redirect "/user-list"
-- >
-- > get "/user-details/:userId" $
-- >   do userId <- param' "userId"
-- >      deleteUrl <- safeActionPath (DeleteUser userId)
-- >      html $ "Click <a href='" <> deleteUrl <> "'>here</a> to delete user!"
--
-- Note that safeActions currently only support GET and POST requests.
--
safeActionPath :: forall conn sess st a.
                  ( SafeAction conn sess st a
                  , HasSpock(SpockAction conn sess st)
                  , SpockConn (SpockAction conn sess st) ~ conn
                  , SpockSession (SpockAction conn sess st) ~ sess
                  , SpockState (SpockAction conn sess st) ~ st)
               => a
               -> SpockAction conn sess st T.Text
safeActionPath safeAction =
    do mgr <- getSessMgr
       hash <- (sm_addSafeAction mgr) (PackedSafeAction safeAction)
       return $ "/h/" <> hash

hookSafeActions :: forall conn sess st.
                   ( HasSpock (SpockAction conn sess st)
                   , SpockConn (SpockAction conn sess st) ~ conn
                   , SpockSession (SpockAction conn sess st) ~ sess
                   , SpockState (SpockAction conn sess st) ~ st)
                => SpockM conn sess st ()
hookSafeActions =
    do get "/h/:spock-csurf-protection" run
       post "/h/:spock-csurf-protection" run
    where
      run =
          do Just h <- param "spock-csurf-protection"
             mgr <- getSessMgr
             mAction <- (sm_lookupSafeAction mgr) h
             case mAction of
               Nothing ->
                   do setStatus Http.status404
                      text "File not found"
               Just p@(PackedSafeAction action) ->
                   do runSafeAction action
                      (sm_removeSafeAction mgr) p
