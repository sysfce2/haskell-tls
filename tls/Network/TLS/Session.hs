module Network.TLS.Session (
    SessionManager (..),
    noSessionManager,
) where

import Network.TLS.Types

-- | A session manager.
-- In the server side, all fields are used.
-- In the client side, only 'sessionEstablish' is used.
data SessionManager = SessionManager
    { sessionResume :: SessionIDorTicket -> IO (Maybe SessionData)
    -- ^ Used on TLS 1.2\/1.3 servers to lookup 'SessionData' with 'SessionID' or to decrypt 'Ticket' to get 'SessionData'.
    , sessionResumeOnlyOnce :: SessionIDorTicket -> IO (Maybe SessionData)
    -- ^ Used for 0RTT on TLS 1.3 servers to lookup 'SessionData' with 'SessionID' or to decrypt 'Ticket' to get 'SessionData'.
    , sessionEstablish :: SessionIDorTicket -> SessionData -> IO (Maybe Ticket)
    -- ^ Used on TLS 1.2\/1.3 servers to store 'SessionData' with 'SessionID' or to encrypt 'SessionData' to get 'Ticket' ignoring 'SessionID'. Used on TLS 1.2\/1.3 clients to store 'SessionData' with 'SessionIDorTicket' and then return 'Nothing'. For clients, only this field should be set with 'noSessionManager'.
    , sessionInvalidate :: SessionIDorTicket -> IO ()
    -- ^ Used TLS 1.2 servers to delete 'SessionData' with 'SessionID' on errors.
    , sessionUseTicket :: Bool
    -- ^ Used on TLS 1.2 servers to decide to use 'SessionID' or 'Ticket'. Note that 'SessionID' and 'Ticket' are integrated as identity in TLS 1.3.
    }

-- | The session manager to do nothing.
noSessionManager :: SessionManager
noSessionManager =
    SessionManager
        { sessionResume = \_ -> return Nothing
        , sessionResumeOnlyOnce = \_ -> return Nothing
        , sessionEstablish = \_ _ -> return Nothing
        , sessionInvalidate = \_ -> return ()
        , -- Don't send NewSessionTicket in TLS 1.2 by default.
          -- Send NewSessionTicket with SessionID in TLS 1.3 by default.
          sessionUseTicket = False
        }
