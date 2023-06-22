import express from "express";
const app = express();
const port = 3000;

app.use(express.static("public"));

app.get("/", (req, res) => {
  res.sendFile("./public/resume.html");
});

app.listen(port, () => {
  return console.log(`Express is listening at http://localhost:${port}`);
});
