#pragma once
#include <string>
#include <vector>
#include <regex>
#include <map>
#include <stdexcept>
namespace sailking {
inline std::string language(const std::string& code) {
    static const std::map<std::string,std::string> languages={{"auto",""},{"zh-Hans","Chinese"},{"zh-Hant","Traditional Chinese"},{"en","English"},{"ja","Japanese"},{"ko","Korean"},{"de","German"},{"fr","French"},{"es","Spanish"},{"pt","Portuguese"},{"id","Indonesian"},{"vi","Vietnamese"},{"th","Thai"},{"ar","Arabic"},{"it","Italian"},{"ru","Russian"},{"hi","Hindi"},{"tr","Turkish"},{"nl","Dutch"},{"pl","Polish"},{"uk","Ukrainian"}};
    auto it=languages.find(code); if(it==languages.end())throw std::runtime_error("Invalid language");return it->second;
}
inline std::vector<std::string> protectedEntities(const std::string& text) {
    static const std::regex re(R"(https?://[^\s<>"']+|[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}|\b[A-Z][A-Z0-9]*(?:[\-_][A-Z0-9]+)+\b|\b[A-Z][A-Z0-9]*[0-9][A-Z0-9]*\b)");
    std::vector<std::string> result;
    for(std::sregex_iterator i(text.begin(),text.end(),re),end;i!=end;++i){
        std::string value=i->str();while(!value.empty()&&std::string(".,;!?)").find(value.back())!=std::string::npos)value.pop_back();
        if(!value.empty())result.push_back(value);
    }return result;
}
inline bool entitiesIntact(const std::string& source,const std::string& result) {
    std::map<std::string,int> expected,actual;
    for(auto& e:protectedEntities(source))++expected[e];for(auto& e:protectedEntities(result))++actual[e];
    for(auto& e:expected)if(actual[e.first]<e.second)return false;return true;
}
inline std::string prompt(const std::string& text,const std::string& source,const std::string& target) {
    std::string s=language(source),t=language(target);if(t.empty()||text.empty()||text.find('\0')!=std::string::npos)throw std::runtime_error("Invalid translation request");
    std::string prefix;std::map<std::string,int> terms;for(auto& e:protectedEntities(text))terms[e]=1;
    if(!terms.empty()){prefix="Reference the following translations:\n";for(auto& e:terms)prefix+=e.first+" translates to "+e.first+"\n";prefix+="\n";}
    return prefix+"Translate the following "+(s.empty()?"text":s+" text")+" into "+t+"."+
        (s.empty()?"":" The source language is "+s+".")+" Note that you should only output the translated result without any additional explanation:\n\n"+text;
}
}
