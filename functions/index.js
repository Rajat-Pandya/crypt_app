const functions = require("firebase-functions");
const admin = require("firebase-admin");

admin.initializeApp();

exports.sendNotification = functions.firestore
  .document("chat_rooms/{roomId}/messages/{messageId}")
  .onCreate(async (snapshot, context) => {

    const messageData = snapshot.data();
    const senderId = messageData.senderId;

    const roomId = context.params.roomId;

    // 🔥 Get chat room
    const roomDoc = await admin.firestore()
      .collection("chat_rooms")
      .doc(roomId)
      .get();

    const participants = roomDoc.data().participants;

    // 🔥 Find receiver
    const receiverId = participants.find(id => id !== senderId);

    // 🔥 Get receiver token
    const userDoc = await admin.firestore()
      .collection("users")
      .doc(receiverId)
      .get();

    const token = userDoc.data().fcmToken;

    if (!token) return;

    // 🔔 Notification payload
    const payload = {
      notification: {
        title: "New Message",
        body: "You received a new message",
      }
    };

    return admin.messaging().sendToDevice(token, payload);
  });