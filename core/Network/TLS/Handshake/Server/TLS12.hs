{-# LANGUAGE OverloadedStrings #-}

module Network.TLS.Handshake.Server.TLS12 (
    recvClientSecondFlight12,
) where

import qualified Data.ByteString as B

import Network.TLS.Context.Internal
import Network.TLS.Handshake.Common
import Network.TLS.Handshake.Key
import Network.TLS.Handshake.Process
import Network.TLS.Handshake.Server.Common
import Network.TLS.Handshake.Signature
import Network.TLS.Handshake.State
import Network.TLS.Parameters
import Network.TLS.State
import Network.TLS.Struct
import Network.TLS.Types
import Network.TLS.X509

recvClientSecondFlight12
    :: ServerParams
    -> Context
    -> Maybe SessionData
    -> IO ()
recvClientSecondFlight12 sparams ctx resumeSessionData = do
    case resumeSessionData of
        Nothing -> do
            recvClientCCC sparams ctx
            sendChangeCipherAndFinish ctx ServerRole
        Just _ -> do
            recvChangeCipherAndFinish ctx
    handshakeDone ctx

-- | receive Client data in handshake until the Finished handshake.
--
--      <- [certificate]
--      <- client key xchg
--      <- [cert verify]
--      <- change cipher
--      <- finish
recvClientCCC :: ServerParams -> Context -> IO ()
recvClientCCC sparams ctx = runRecvState ctx (RecvStateHandshake processClientCertificate)
  where
    processClientCertificate (Certificates certs) = do
        clientCertificate sparams ctx certs

        -- FIXME: We should check whether the certificate
        -- matches our request and that we support
        -- verifying with that certificate.

        return $ RecvStateHandshake processClientKeyExchange
    processClientCertificate p = processClientKeyExchange p

    -- cannot use RecvStateHandshake, as the next message could be a ChangeCipher,
    -- so we must process any packet, and in case of handshake call processHandshake manually.
    processClientKeyExchange (ClientKeyXchg _) = return $ RecvStatePacket processCertificateVerify
    processClientKeyExchange p = unexpected (show p) (Just "client key exchange")

    -- Check whether the client correctly signed the handshake.
    -- If not, ask the application on how to proceed.
    --
    processCertificateVerify (Handshake [hs@(CertVerify dsig)]) = do
        processHandshake ctx hs

        certs <- checkValidClientCertChain ctx "change cipher message expected"

        usedVersion <- usingState_ ctx getVersion
        -- Fetch all handshake messages up to now.
        msgs <- usingHState ctx $ B.concat <$> getHandshakeMessages

        pubKey <- usingHState ctx getRemotePublicKey
        checkDigitalSignatureKey usedVersion pubKey

        verif <- checkCertificateVerify ctx usedVersion pubKey msgs dsig
        clientCertVerify sparams ctx certs verif
        return $ RecvStatePacket expectChangeCipher
    processCertificateVerify p = do
        chain <- usingHState ctx getClientCertChain
        case chain of
            Just cc
                | isNullCertificateChain cc -> return ()
                | otherwise ->
                    throwCore $ Error_Protocol "cert verify message missing" UnexpectedMessage
            Nothing -> return ()
        expectChangeCipher p

    expectChangeCipher ChangeCipherSpec = do
        return $ RecvStateHandshake expectFinish
    expectChangeCipher p = unexpected (show p) (Just "change cipher")

    expectFinish (Finished _) = return RecvStateDone
    expectFinish p = unexpected (show p) (Just "Handshake Finished")

clientCertVerify :: ServerParams -> Context -> CertificateChain -> Bool -> IO ()
clientCertVerify sparams ctx certs verif = do
    if verif
        then do
            -- When verification succeeds, commit the
            -- client certificate chain to the context.
            --
            usingState_ ctx $ setClientCertificateChain certs
            return ()
        else do
            -- Either verification failed because of an
            -- invalid format (with an error message), or
            -- the signature is wrong.  In either case,
            -- ask the application if it wants to
            -- proceed, we will do that.
            res <- onUnverifiedClientCert (serverHooks sparams)
            if res
                then do
                    -- When verification fails, but the
                    -- application callbacks accepts, we
                    -- also commit the client certificate
                    -- chain to the context.
                    usingState_ ctx $ setClientCertificateChain certs
                else decryptError "verification failed"