const {onCall,HttpsError}=require("firebase-functions/v2/https");
const {setGlobalOptions}=require("firebase-functions/v2/options");
const admin=require("firebase-admin");
const crypto=require("crypto");

admin.initializeApp();
setGlobalOptions({region:"us-central1",maxInstances:5,invoker:"public"});

const db=admin.firestore();

// Kept server-side so activation-code writes/redemption are never trusted to
// the Flutter client. Move this value to Secret Manager before public launch.
const OWNER_ADMIN_PIN=process.env.OWNER_ADMIN_PIN || "116936";

function requireAuth(request){
  if(!request.auth || !request.auth.uid){
    throw new HttpsError("unauthenticated","يجب تسجيل الدخول.");
  }
  return request.auth.uid;
}

exports.generateActivationCode=onCall(async(request)=>{
  const uid=requireAuth(request);
  const pin=String(request.data?.adminPin || "");
  if(pin !== OWNER_ADMIN_PIN){
    throw new HttpsError("permission-denied","رمز المالك غير صحيح.");
  }

  for(let attempt=0;attempt<100;attempt++){
    const code=String(crypto.randomInt(100000,1000000));
    const ref=db.collection("activation_codes").doc(code);
    try{
      await ref.create({
        used:false,
        createdAt:admin.firestore.FieldValue.serverTimestamp(),
        createdByUid:uid,
        deviceId:String(request.data?.deviceId || ""),
      });
      return {success:true,code};
    }catch(error){
      if(error.code===6 || error.code==="already-exists") continue;
      console.error("activation create failed",error);
      throw new HttpsError("internal","تعذر إنشاء رمز التفعيل.");
    }
  }

  throw new HttpsError("resource-exhausted","تعذر إنشاء رمز فريد حالياً.");
});

exports.redeemActivationCode=onCall(async(request)=>{
  const uid=requireAuth(request);
  const code=String(request.data?.code || "").replace(/\D/g,"");
  if(!/^\d{6}$/.test(code)){
    throw new HttpsError("invalid-argument","رمز التفعيل غير صالح.");
  }

  const ref=db.collection("activation_codes").doc(code);
  const result=await db.runTransaction(async(tx)=>{
    const snap=await tx.get(ref);
    if(!snap.exists) return false;
    const data=snap.data() || {};
    if(data.used===true) return false;

    tx.update(ref,{
      used:true,
      usedAt:admin.firestore.FieldValue.serverTimestamp(),
      usedUid:uid,
      usedDeviceId:String(request.data?.deviceId || ""),
    });

    return true;
  });

  if(!result){
    return {success:false};
  }

  await db.collection("users").doc(uid).set({
    activated:true,
    activatedAt:admin.firestore.FieldValue.serverTimestamp(),
    activatedDeviceId:String(request.data?.deviceId || ""),
  },{merge:true});

  return {success:true};
});
