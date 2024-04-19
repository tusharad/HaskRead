{-# LANGUAGE OverloadedStrings #-}
module ScottyCrud.Auth.Handler where

import           Web.Scotty
import qualified Data.Text as T
import           Data.Scientific (toBoundedInteger)
import           Data.Maybe (fromMaybe)
import           Data.Password.Bcrypt
import           Web.JWT
import           ScottyCrud.Common.Types
import           ScottyCrud.Query
import           Web.Scotty.Cookie
import           ScottyCrud.HTML.Auth
import           Text.Blaze.Html.Renderer.Text ( renderHtml )
import           Data.Aeson
import qualified Data.Map.Strict as Map

getSignupR :: ActionM ()
getSignupR = do
    mMsg <- queryParamMaybe "message"
    html $ renderHtml $ signUpPage mMsg

getLoginR :: ActionM ()
getLoginR = do
    mUser <- getAuthUser
    mMsg <- queryParamMaybe "message"
    case mUser of
      Just _ -> redirect "/"
      Nothing -> html $ renderHtml $ loginPage mMsg

postSignupUserR :: ActionM ()
postSignupUserR = do
    (userName :: T.Text) <- formParam "userName"
    (email :: T.Text) <- formParam "email"
    (password :: T.Text) <- formParam "password"
    (confirmPassword :: T.Text) <- formParam "confirm_password"
    userNameList <- liftIO $ fetchUserByUserNameQ userName
    userList <- liftIO $ fetchUserByEmailQ email
    case userList of
        [] ->  do
          case userNameList of
            [] -> if password /= confirmPassword then redirect "/signup?message=password is did not matched" else liftIO (addUserQ email password userName) >> redirect "/"
            _ -> redirect "/signup?message=user name is taken"
        _  -> redirect "/login?message=user already exist"

postLoginUserR :: ActionM ()
postLoginUserR = do
    (email :: T.Text)     <- formParam "email"
    (password_ :: String) <- formParam "password"
    userList              <- liftIO $ fetchUserByEmailQ email
    case userList of
        [] -> text "sign up first :("
        [user]  -> do
            let hashedPassword = password user
            case checkPassword (mkPassword (T.pack password_)) (PasswordHash (T.pack hashedPassword)) of
              PasswordCheckSuccess -> setSimpleCookie "auth_token" (jwtEncryptUserId (user_id user)) >> redirect "/"
              _                    -> text "password is wrong!!"
        _       -> undefined

getLogoutR :: ActionM ()
getLogoutR = deleteCookie "auth_token" >> redirect "/"

putPasswordResetR :: ActionM ()
putPasswordResetR = do
    mUser <- getAuthUser
    case mUser of
      Nothing -> redirect "/?message=user not valid"
      Just user -> do
        currentPassword <- formParam "current_password"
        newPassword  <- formParam "new_password"
        confirmPassword <- formParam "confirm_password"
        if (newPassword /= confirmPassword) then redirect "/?message=passwords not matching" 
        else do
          case checkPassword (mkPassword (currentPassword)) (PasswordHash (T.pack $ password user)) of
            PasswordCheckSuccess -> (liftIO $ updateUserPasswordQ (user_id user) newPassword) >> redirect "/?message=password has been updated"
            _                    -> redirect "/?message=password is wrong"

jwtEncryptUserId :: Int -> T.Text
jwtEncryptUserId userId = do
  let key = hmacSecret . T.pack $ "hello cat"
  let cs = mempty {
          iss = stringOrURI . T.pack $ "Foo"
        , unregisteredClaims = ClaimsMap $ Map.fromList [(T.pack "user_id", Number $ fromIntegral userId)]
      }
  encodeSigned key mempty cs

fetchUserIdFromJWT :: JWTClaimsSet -> Maybe Value
fetchUserIdFromJWT res = Map.lookup "user_id" $ unClaimsMap $ unregisteredClaims res

checkIfUserIdIsValid :: Value -> IO (Maybe User)
checkIfUserIdIsValid (Number user_id) = do
    let user_id' = fromMaybe (0 :: Int) $ toBoundedInteger user_id
    userList <- getUserByIdQ user_id'
    case userList of
      []     -> pure Nothing
      [user] -> pure $ Just user
      _      -> undefined
checkIfUserIdIsValid _ = undefined

getAuthUser_ :: Maybe T.Text -> IO (Maybe User)
getAuthUser_ Nothing = pure Nothing
getAuthUser_ (Just encryptedData)= do
  let mRes = claims <$> decodeAndVerifySignature (toVerify . hmacSecret . T.pack $ "hello cat") encryptedData
      res = mRes >>= fetchUserIdFromJWT
  case res of
    Nothing -> pure Nothing
    Just r  -> checkIfUserIdIsValid r

getAuthUser :: ActionM (Maybe User)
getAuthUser = do
    mUserId <- getCookie "auth_token"
    liftIO $ getAuthUser_ mUserId